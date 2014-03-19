use strict;
use warnings;

package OESS::FV;

use Log::Log4perl;
use Graph::Directed;
use OESS::Database;
use OESS::DBus;
use JSON::XS;
use Time::HiRes;

#link statuses
use constant OESS_LINK_UP       => 1;
use constant OESS_LINK_DOWN     => 0;
use constant OESS_LINK_UNKNOWN  => 2;
#node status
use constant OESS_NODE_UP       => 1;
use constant OESS_NODE_DOWN     => 0;

=head1 NAME

OESS::FV - Forwarding Verification

=head1 SYNOPSIS

this is a module used by oess-bfd to provide the bfd link capabilities in OESS and fail over circuits when a
bi-directional or uni-directional link failure is detected
    
=cut


=head2 new

    Creates a new OESS::FV object

=cut

sub new{
    my $that  = shift;
    my $class = ref($that) || $that;

    my $logger = Log::Log4perl->get_logger("OESS::FV");

    my %args = (
        interval => 1000,
	timeout => 15000,
	@_
        );

    my $self = \%args;

    bless $self, $class;
    $self->{'first_run'} = 1;
    $self->{'logger'} = $logger;

    my $db = OESS::Database->new();
    if(!defined($db)){
	$self->{'logger'}->error("error creating database object");
	return;
    }
    $self->{'db'} = $db;

    $self->{'packet_in_count'} = 0;
    $self->{'packet_out_count'} = 0;
    $self->_load_state();
    $self->_connect_to_dbus();

    return $self;
}

sub _load_state(){
    my $self = shift;
    my $links = $self->{'db'}->get_current_links();

    my %nodes;
    my $nodes = $self->{'db'}->get_current_nodes();
    foreach my $node (@$nodes) {
        $nodes{$node->{'dpid'}} = $node;
        
	if(defined($self->{'nodes'}->{$node->{'dpid'}})){
	    $node->{'status'} = $self->{'nodes'}->{$node->{'dpid'}}->{'status'};
	}else{
	    if($node->{'operational_state'} eq 'up'){
		$node->{'status'} = OESS_NODE_UP;
	    }else{
		$node->{'status'} = OESS_NODE_DOWN;
	    }
	}
	
	$nodes{$node->{'node_id'}} = $node;
	$nodes{$node->{'dpid'}} = $node;

    }

    my %links;
    foreach my $link (@$links) {
	if ($link->{'status'} eq 'up') {
            $link->{'status'} = OESS_LINK_UP;
	} elsif ($link->{'status'} eq 'down') {
            $link->{'status'} = OESS_LINK_DOWN;
	} else {
            $link->{'status'} = OESS_LINK_UNKNOWN;
        }


        my $int_a = $self->{'db'}->get_interface( interface_id => $link->{'interface_a_id'} );
        my $int_z = $self->{'db'}->get_interface( interface_id => $link->{'interface_z_id'} );

	$link->{'a_node'} = $nodes{$nodes{$int_a->{'node_id'}}->{'dpid'}};
	$link->{'a_port'} = $int_a;
	$link->{'z_node'} = $nodes{$nodes{$int_z->{'node_id'}}->{'dpid'}};
	$link->{'z_port'} = $int_z;
	
	if(defined($self->{'links'}->{$link->{'name'}})){
	    $link->{'fv_status'} = $self->{'links'}->{$link->{'name'}}->{'fv_status'};
	    $link->{'last_verified'} = $self->{'links'}->{$link->{'name'}}->{'last_verified'};
	}else{
	    $link->{'last_verified'} = Time::HiRes::time() * 1000;
	    $link->{'fv_status'} = OESS_LINK_UNKNOWN;
	}

        $links{$link->{'name'}} = $link;
    }
    
    $self->{'logger'}->debug("Node State: " . Data::Dumper::Dumper(\%nodes));
    $self->{'logger'}->debug("Link State: " . Data::Dumper::Dumper(\%links));
    
    $self->{'nodes'} = \%nodes;
    $self->{'links'} = \%links;
    
    return;

}

sub _connect_to_dbus{
    my $self = shift;

    $self->{'logger'}->debug("Connecting to DBus");
    my $dbus = OESS::DBus->new( service => "org.nddi.openflow",
                                instance => "/controller1", sleep_interval => .1, timeout => -1);
    if(!defined($dbus)){
        $self->{'logger'}->crit("Error unable to connect to DBus");
        die;
    }

    $dbus->connect_to_signal("datapath_leave",sub{ $self->datapath_leave_callback(@_)});
    $dbus->connect_to_signal("datapath_join",sub {$self->datapath_join_callback( @_ )});
    $dbus->connect_to_signal("link_event",  sub { $self->link_event_callback( @_ )});
    $dbus->connect_to_signal("port_status", sub { $self->port_status_callback( @_ )});
    $dbus->connect_to_signal("fv_packet_in", sub { $self->fv_packet_in_callback( @_ ) });
    
    my $bus = Net::DBus->system;

    my $client;
    my $service;
    eval {
        $service = $bus->get_service("org.nddi.openflow");
        $client  = $service->get_object("/controller1");
    };

    if ($@){
        warn "Error in _conect_to_dbus: $@";
        return undef;
    }
    
    $client->register_for_fv_in( $self->{'db'}->{'discovery_vlan'} );

    $self->{'dbus'} = $client;

    $dbus->start_reactor( timeouts => [{interval => 300000, callback => Net::DBus::Callback->new(
                                            method => sub { $self->_load_state(); })},
                                       {interval => $self->{'interval'}, callback => Net::DBus::Callback->new(
                                            method => sub { $self->do_work(); })}]);
    
}

sub datapath_leave_callback{
    my $self = shift;
    my $dpid = shift;

    $self->{'logger'}->debug("Node: " .$dpid ." has left");
    $self->{'logger'}->warn("Node: " . $self->{'nodes'}->{$dpid}->{'name'} . " has left");
    $self->{'nodes'}->{$dpid}->{'status'} = OESS_NODE_DOWN;
    
}

sub datapath_join_callback{
    my $self = shift;
    my $dpid = shift;

    $self->{'logger'}->debug("Node: " . $dpid . " has joined");
    $self->{'logger'}->warn("Node: " . $self->{'nodes'}->{$dpid}->{'name'} . " has joined");
    $self->{'nodes'}->{$dpid}->{'status'} = OESS_NODE_UP;
    
}

sub link_event_callback{
    my $self = shift;
    my $a_dpid = shift;
    my $a_port = shift;
    my $z_dpid = shift;
    my $z_port = shift;
    my $status = shift;

    $self->_load_state();
    
}


sub port_status_callback{
    my $self = shift;
    my $dpid = shift;
    my $reason = shift;
    my $info = shift;


    my $port_number = $info->{'port_no'};
    my $link_status = $info->{'link'};

    #if the link didn't go up ignore it!
    if($link_status != 1){
	return;
    }

    #ok link came up... is it a part of a link
    foreach my $link_name (keys (%{$self->{'links'}})){
	if($self->{'links'}->{$link_name}->{'a_node'}->{'dpid'} == $dpid && $self->{'links'}->{$link_name}->{'a_port'}->{'port_number'} == $port_number){
	    $self->{'links'}->{$link_name}->{'fv_status'} = OESS_LINK_UNKNOWN;
	    $self->{'links'}->{$link_name}->{'last_verified'} = Time::HiRes::time() * 1000;
	    delete $self->{'last_heard'}->{$self->{'links'}->{$link_name}->{'a_node'}->{'dpid'}}->{$self->{'links'}->{$link_name}->{'a_port'}->{'port_number'}};
	    delete $self->{'last_heard'}->{$self->{'links'}->{$link_name}->{'z_node'}->{'dpid'}}->{$self->{'links'}->{$link_name}->{'z_port'}->{'port_number'}};									 
	}

	if($self->{'links'}->{$link_name}->{'z_node'}->{'dpid'} == $dpid && $self->{'links'}->{$link_name}->{'z_port'}->{'port_number'} == $port_number){
	    $self->{'links'}->{$link_name}->{'fv_status'} = OESS_LINK_UNKNOWN;
            $self->{'links'}->{$link_name}->{'last_verified'} =Time::HiRes::time() * 1000;
            delete $self->{'last_heard'}->{$self->{'links'}->{$link_name}->{'a_node'}->{'dpid'}}->{$self->{'links'}->{$link_name}->{'a_port'}->{'port_number'}};
            delete $self->{'last_heard'}->{$self->{'links'}->{$link_name}->{'z_node'}->{'dpid'}}->{$self->{'links'}->{$link_name}->{'z_port'}->{'port_number'}};
	}
    }
    
}

sub do_work{
    my $self = shift;
    
    if(-e '/var/run/oess_is_overloaded.lock'){
	$self->{'logger'}->warn("OESS OVERLOADED file exists FVD is disabled");
	foreach my $link_name (keys(%{$self->{'links'}})){
	    $self->{'links'}->{$link_name}->{'fv_status'} = OESS_LINK_UNKNOWN;
            $self->{'links'}->{$link_name}->{'last_verified'} = Time::HiRes::time() * 1000;
	}
	return;
    }

    $self->{'logger'}->debug("checking forwarding on links");
    foreach my $link_name (keys(%{$self->{'links'}})){
		
	my $link = $self->{'links'}->{$link_name};
	
	$self->{'logger'}->debug("Checking Forwarding on link: " . $link->{'name'});
	my $a_end = {node => $link->{'a_node'}, int => $link->{'a_port'}};
	my $z_end = {node => $link->{'z_node'}, int => $link->{'z_port'}};
	
	if($self->{'nodes'}->{$a_end->{'node'}->{'dpid'}}->{'status'} == OESS_NODE_DOWN){
            $self->{'logger'}->info("node " . $a_end->{'node'}->{'name'} . " is down not checking link: " . $link->{'name'});
	    $self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_UNKNOWN;
	    $self->{'links'}->{$link->{'name'}}->{'last_verified'} = Time::HiRes::time() * 1000;
	    next;
        }

        if($self->{'nodes'}->{$z_end->{'node'}->{'dpid'}}->{'status'} == OESS_NODE_DOWN){
            $self->{'logger'}->info("node " . $z_end->{'node'}->{'name'} . " is down not checking link: " . $link->{'name'});
	    $self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_UNKNOWN;
	    $self->{'links'}->{$link->{'name'}}->{'last_verified'} = Time::HiRes::time() * 1000;
            next;
        }

	if(!defined($self->{'last_heard'}->{$a_end->{'node'}->{'dpid'}}->{$a_end->{'int'}->{'port_number'}}) ||
	   !defined($self->{'last_heard'}->{$z_end->{'node'}->{'dpid'}}->{$z_end->{'int'}->{'port_number'}})){
	    #we have never received it at least not since we were started...
	    if($self->{'links'}->{$link->{'name'}}->{'fv_status'} == OESS_LINK_UP){
		$self->{'logger'}->error("An error has occurred Forwarding Verification, considering link " . $link->{'name'} . " down");
		#fire link down
		$self->_send_fwdctl_link_event(link_name => $link->{'name'} , state => OESS_LINK_DOWN );
		$self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_DOWN;
		$self->{'links'}->{$link->{'name'}}->{'last_verified'} = Time::HiRes::time() * 1000;
	    }elsif($self->{'links'}->{$link->{'name'}}->{'fv_status'} == OESS_LINK_UNKNOWN){
		$self->{'logger'}->debug("Last verified: " . ((Time::HiRes::time() * 1000) - $self->{'links'}->{$link->{'name'}}->{'last_verified'}) . " ms ago");
		if(((Time::HiRes::time() * 1000) - $self->{'links'}->{$link->{'name'}}->{'last_verified'}) > $self->{'timeout'}){
		    $self->{'logger'}->warn("Forwarding verification for link: " . $link->{'name'} . " has not been verified since load... timeout has passed considering down");
		    $self->_send_fwdctl_link_event(link_name => $link->{'name'} , state =>OESS_LINK_DOWN );
		    $self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_DOWN;
		    $self->{'links'}->{$link->{'name'}}->{'last_verified'} = Time::HiRes::time() * 1000;
		}else{
		    $self->{'logger'}->warn("Forwarding verification for link: " . $link->{'name'} . " has not been verified yet... still unknown");
		}
	    }
	    #no need to do more work... go to next one
	    next;
	}
	
	#verify both ends came and went from the right nodes/interfaces
	if($self->{'last_heard'}->{$a_end->{'node'}->{'dpid'}}->{$a_end->{'int'}->{'port_number'}}->{'originator'}->{'dpid'} eq $z_end->{'node'}->{'dpid'} &&
	   $self->{'last_heard'}->{$a_end->{'node'}->{'dpid'}}->{$a_end->{'int'}->{'port_number'}}->{'originator'}->{'port_number'} eq $z_end->{'int'}->{'port_number'} &&
	   $self->{'last_heard'}->{$z_end->{'node'}->{'dpid'}}->{$z_end->{'int'}->{'port_number'}}->{'originator'}->{'dpid'} eq $a_end->{'node'}->{'dpid'} &&
	   $self->{'last_heard'}->{$z_end->{'node'}->{'dpid'}}->{$z_end->{'int'}->{'port_number'}}->{'originator'}->{'port_number'} eq $a_end->{'int'}->{'port_number'}){
	    
	    $self->{'logger'}->debug("Packet origins/outputs line up with what we expected");
	    
	    my $last_verified_a_z = ((Time::HiRes::time() * 1000) - ($self->{'last_heard'}->{$a_end->{'node'}->{'dpid'}}->{$a_end->{'int'}->{'port_number'}}->{'timestamp'} * 1000));
	    my $last_verified_z_a = ((Time::HiRes::time() * 1000) - ($self->{'last_heard'}->{$z_end->{'node'}->{'dpid'}}->{$z_end->{'int'}->{'port_number'}}->{'timestamp'} * 1000));
	    
	    $self->{'logger'}->debug("Link: " . $link->{'name'} . " Z -> A last verified " . $last_verified_z_a . "ms ago");
	    $self->{'logger'}->debug("Link: " . $link->{'name'} . " A -> Z last verified " . $last_verified_a_z . "ms ago");
	    
	    #verify the last heard time is good
	    if( $last_verified_a_z < $self->{'timeout'} && 
	        $last_verified_z_a < $self->{'timeout'} ){
		$self->{'logger'}->debug("link " . $link->{'name'} . " is operating as expected");
		#link is good
		if($self->{'links'}->{$link->{'name'}}->{'fv_status'} == OESS_LINK_DOWN){
		    $self->{'logger'}->warn("Link: " . $link->{'name'} . " forwarding restored!");
		    #fire link up
		    $self->_send_fwdctl_link_event(link_name => $link->{'name'} , state =>OESS_LINK_UP );
		    $self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_UP;
		    $self->{'links'}->{$link->{'name'}}->{'last_verified'} = Time::HiRes::time() * 1000;
		}else{
		    if($self->{'links'}->{$link->{'name'}}->{'fv_status'} == OESS_LINK_UNKNOWN){
			$self->_send_fwdctl_link_event(link_name => $link->{'name'} , state => OESS_LINK_UP );
		    }
		    $self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_UP;
		    $self->{'logger'}->debug("link " . $link->{'name'} . " is still up");
		    $self->{'links'}->{$link->{'name'}}->{'last_verified'} = Time::HiRes::time() * 1000;
		}
	    }else{
		$self->{'logger'}->debug("Link: " . $link->{'name'} . " is not function properly");
		#link is bad!
		if($self->{'links'}->{$link->{'name'}}->{'fv_status'} == OESS_LINK_UP){
		    $self->{'logger'}->warn("Link " . $link->{'name'} . " forwarding disrupted!!!! Considered DOWN!");
		    #fire link down
		    $self->_send_fwdctl_link_event( link_name => $link->{'name'} , state => OESS_LINK_DOWN );
		    $self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_DOWN;
		}elsif($self->{'links'}->{$link->{'name'}}->{'fv_status'} == OESS_LINK_UNKNOWN){
		    if(((Time::HiRes::time() * 1000) - $self->{'links'}->{$link->{'name'}}->{'last_verified'}) > $self->{'timeout'}){
			$self->{'logger'}->warn("Forwarding verification for link: " . $link->{'name'} . " has not been verified since last unknown state... timeout has passed considering down");
			$self->_send_fwdctl_link_event(link_name => $link->{'name'} , state =>OESS_LINK_DOWN );
			$self->{'links'}->{$link->{'name'}}->{'fv_status'} = OESS_LINK_DOWN;
			$self->{'links'}->{$link->{'name'}}->{'last_verified'} = Time::HiRes::time() * 1000;
		    }else{
			#still waiting for timeout
		    }
		}else{
		    $self->{'logger'}->debug("Link " . $link->{'name'} . " is still down");
		}
	    }
	}else{
	    #uh oh the endpoints don't line up... update our db records (maybe a migration/node insertion happened) other wise we are busted... things will timeout
		$self->{'logger'}->error("packet are screwed up!@!@! This can't happen");
		$self->_load_state();	
	}
	$self->{'logger'}->debug("Done processing link");
    }


    #ok now send out our packets
    foreach my $link_name (keys(%{$self->{'links'}})){

	my $link = $self->{'links'}->{$link_name};
	$self->{'logger'}->debug("Sending packets for link: " . $link_name);
        my $a_end = {node => $link->{'a_node'}, int => $link->{'a_port'}};
	my $z_end = {node => $link->{'z_node'}, int => $link->{'z_port'}};


	my $res = $self->{'dbus'}->send_fv_packet(Net::DBus::dbus_uint64($a_end->{'node'}->{'dpid'}),
						  Net::DBus::dbus_uint16($a_end->{'int'}->{'port_number'}),
						  Net::DBus::dbus_uint64($z_end->{'node'}->{'dpid'}),
						  Net::DBus::dbus_uint16($z_end->{'int'}->{'port_number'}),
                                                  Net::DBus::dbus_uint16($self->{'db'}->{'discovery_vlan'}));
	$self->{'packet_out_count'}++;
	$res    = $self->{'dbus'}->send_fv_packet(Net::DBus::dbus_uint64($z_end->{'node'}->{'dpid'}),
						  Net::DBus::dbus_uint16($z_end->{'int'}->{'port_number'}),
						  Net::DBus::dbus_uint64($a_end->{'node'}->{'dpid'}),
						  Net::DBus::dbus_uint16($a_end->{'int'}->{'port_number'}),
                                                  Net::DBus::dbus_uint16($self->{'db'}->{'discovery_vlan'}));
	$self->{'packet_out_count'}++;
	$self->{'logger'}->debug("Done sending packets");
    }

}

    
sub fv_packet_in_callback{
    my $self = shift;
    my $dpid = shift;
    my $port = shift;
    my $packet = shift;


    $self->{'first_run'} = 0;
    $self->{'logger'}->debug("FV Packet received!");
    my $string;

    #throw away the header because we don't care
    $self->{'packet_in_count'}++;
    $self->{'logger'}->debug("Packet In Count: " . $self->{'packet_in_count'});
    $self->{'logger'}->debug("Packet Out Count: " . $self->{'packet_out_count'});


    $self->{'logger'}->debug("RAW PACKET: " . Data::Dumper::Dumper($packet));
    splice (@$packet,0,28);

    if($packet->[0] == 0){
	splice(@$packet,0,4);
    }
    
    $string = pack("C*",@$packet);
    $self->{'logger'}->debug("RAW STRING: " . $string);
    my $obj;

    eval{
	$obj = decode_json($string);
    };

    if(!defined($obj)){
	$self->{'logger'}->error("Unable to parse JSON string: " . $string);
	return;
    }

    $self->{'logger'}->debug("JSON: " . $string);

    if($obj->{'dst_dpid'} != $dpid){
	$self->{'logger'}->error("Packet said it should have gone to " . $obj->{'dst_dpid'} . " but OpenFlow said it was from " . $dpid);
	return;
    }
    if($obj->{'dst_port_id'} != $port){
	$self->{'logger'}->error("Packet said it should have gone to port " . $obj->{'dst_port_id'} . " but openflow said it was from " . $port);
	return;
    }
    
    $self->{'last_heard'}->{$dpid}->{$port} = {originator => {dpid => $obj->{'src_dpid'}, port_number => $obj->{'src_port_id'}},
					       timestamp => $obj->{'timestamp'}};

    $self->{'logger'}->debug("Done Processing Packet");
}


sub _send_fwdctl_link_event{
    my $self = shift;
    my %args = @_;

    my $bus = Net::DBus->system;

    my $link_name = $args{'link_name'};
    my $state = $args{'state'};

    my $client;
    my $service;

    eval {
        $service = $bus->get_service("org.nddi.fwdctl");
	$client  = $service->get_object("/controller1");
    };

    if ($@) {
        $self->{'logger'}->error( "Error in _connect_to_fwdctl: $@");
	return;
    }

    if ( !defined $client ) {
        return;
    }
    
    eval{
	my $result = $client->fv_link_event( $link_name, $state );
	return $result;
    }
}

1;