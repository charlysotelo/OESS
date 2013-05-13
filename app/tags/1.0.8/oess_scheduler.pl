#!/usr/bin/perl

use strict;
use OESS::Database;
use OESS::DBus;
use XML::Simple;
use Sys::Syslog qw(:standard :macros);
use Data::Dumper;

sub main{
    openlog("oess_scheduler.pl", 'cons,pid', LOG_DAEMON);
    my $time = time();

    my $oess = OESS::Database->new();
    
    my $bus = Net::DBus->system;
    my $service;
    my $client;

    eval {
        $service = $bus->get_service("org.nddi.fwdctl");
        $client  = $service->get_object("/controller1");
    };

    if ($@){
        syslog(LOG_ERR,"Error in _connect_to_fwdctl: $@");
        return undef;
    }

	 my $log_svc;
     my $log_client;

    eval {
        $log_svc    = $bus->get_service("org.nddi.notification");
        $log_client = $log_svc->get_object("/controller1");
    };


    my $actions = $oess->get_current_actions();

    foreach my $action (@$actions){
	
        my $circuit_layout = XMLin($action->{'circuit_layout'}, forcearray => 1);
	
        if($circuit_layout->{'action'} eq 'provision'){
            syslog(LOG_DEBUG,"Circuit " . $circuit_layout->{'name'} . ":" . $circuit_layout->{'circuit_id'} . " scheduled for activation NOW!");
            my $user = $oess->get_user_by_id( user_id => $action->{'user_id'} )->[0];
            my $ckt = $oess->get_circuit_by_id( circuit_id => $action->{'circuit_id'})->[0];
            #edit the circuit to make it active
            my $output = $oess->edit_circuit(circuit_id     => $action->{'circuit_id'},
                                             name           => $circuit_layout->{'name'},
                                             bandwidth      => $circuit_layout->{'bandwidth'},
                                             provision_time => time(),
                                             remove_time    => -1,
                                             links          => $circuit_layout->{'links'},
                                             backup_links   => $circuit_layout->{'backup_links'},
                                             nodes          => $circuit_layout->{'nodes'},
                                             interfaces     => $circuit_layout->{'interfaces'},
                                             tags           => $circuit_layout->{'tags'},
                                             status         => 'active',
                                             user_name      => $user->{'auth_name'},
                                             workgroup_id   => $action->{'workgroup_id'},
                                             description    => $ckt->{'description'}
                                            );

            my $res;
            eval {
                $res = $client->addVlan($output->{'circuit_id'});
            };
            
            $oess->update_action_complete_epoch( scheduled_action_id => $action->{'scheduled_action_id'});
            
            eval {
                $log_client->circuit_provision({ circuit_id => $action->{'circuit_id'} } );
            };
            
            
        } elsif($circuit_layout->{'action'} eq 'edit'){
            syslog(LOG_DEBUG,"Circuit " . $circuit_layout->{'name'} . ":" . $circuit_layout->{'circuit_id'} . " scheduled for edit NOW!");
            my $res;
            eval {
                $res = $client->deleteVlan($action->{'circuit_id'});
            };
            
            my $ckt = $oess->get_circuit_by_id(circuit_id => $action->{'circuit_id'})->[0];
            my $user = $oess->get_user_by_id( user_id => $action->{'user_id'} )->[0];
            my $output = $oess->edit_circuit(circuit_id => $action->{'circuit_id'},
                                             name => $circuit_layout->{'name'},
                                             bandwidth => $circuit_layout->{'bandwidth'},
                                             provision_time => time(),
                                             remove_time => -1,
                                             links => $circuit_layout->{'links'},
                                             backup_links => $circuit_layout->{'backup_links'},
                                             nodes => $circuit_layout->{'nodes'},
                                             interfaces => $circuit_layout->{'interfaces'},
                                             tags => $circuit_layout->{'tags'},
                                             status => 'active',
                                             username => $user->{'auth_name'},
                                             workgroup_id => $action->{'workgroup_id'},
                                             description => $ckt->{'description'}
                                            );
            
            $res = undef;
            
            eval{ 
                $res = $client->addVlan($output->{'circuit_id'});
            };
            
            $oess->update_action_complete_epoch( scheduled_action_id => $action->{'scheduled_action_id'});
            
            eval{
                $log_client->circuit_modify({ circuit_id    => $action->{'circuit_id'} });
            };

        }
        elsif($circuit_layout->{'action'} eq 'remove'){
            syslog(LOG_ERR, "Circuit " . $circuit_layout->{'name'} . ":" . $action->{'circuit_id'} . " scheduled for removal NOW!");
            my $res;
            eval{
                $res = $client->deleteVlan($action->{'circuit_id'});
            };
	    
            if(!defined($res)){
                syslog(LOG_ERR,"Res was not defined");
            }
	    
            syslog(LOG_DEBUG,"Res: '" . $res . "'");
            my $user = $oess->get_user_by_id( user_id => $action->{'user_id'} )->[0];
            $res = $oess->remove_circuit( circuit_id => $action->{'circuit_id'}, remove_time => time(), username => $user->{'auth_name'});
            
	    
	    
            if(!defined($res)){
                syslog(LOG_ERR,"unable to remove circuit");
                $oess->_rollback();
                die;
            }else{
                
                $res = $oess->update_action_complete_epoch( scheduled_action_id => $action->{'scheduled_action_id'});
		
		
                if(!defined($res)){
                    syslog(LOG_ERR,"Unable to complete action");
                    $oess->_rollback();
                }
            }
        
            #Delete is complete and successful, send event on DBUS Channel Notification listens on.
		
            eval {
                $log_client->circuit_decommission({ circuit_id    => $action->{'circuit_id'} });
            };

        }elsif($circuit_layout->{'action'} eq 'change_path'){
            syslog(LOG_ERR,"Found a change_path action!!\n");
            #verify the circuit has an alternate path
            my $circuit_details = $oess->get_circuit_details( circuit_id => $action->{'circuit_id'} );
            
            #if we are already on our scheduled path... don't change
            if($circuit_details->{'active_path'} ne $circuit_layout->{'path'}){
                syslog(LOG_INFO,"Changing the patch of circuit " . $circuit_details->{'description'} . ":" . $circuit_details->{'circuit_id'});
                my $success = $oess->switch_circuit_to_alternate_path( circuit_id => $action->{'circuit_id'} );
                my $res;
                if($success){
                    eval{
                        $res = $client->changeVlanPath($action->{'circuit_id'});
                    };
                }

		$res = $oess->update_action_complete_epoch( scheduled_action_id => $action->{'scheduled_action_id'});

                if(!defined($res)){
                    syslog(LOG_ERR,"Unable to complete action");
                    $oess->_rollback();
                }
                $log_client->circuit_restore_to_primary( { circuit_id    => $action->{'circuit_id'},
                                                           
                                                         }
                                                       );

            }else{
                #already done... nothing to do... complete the scheduled action
                syslog(LOG_WARNING,"Circuit " . $circuit_details->{'description'} . ":" . $circuit_details->{'circuit_id'} . " is already on Path:" . $circuit_layout->{'path'} . "completing scheduled action"); 
                my $res = $oess->update_action_complete_epoch( scheduled_action_id => $action->{'scheduled_action_id'});

                if(!defined($res)){
                    syslog(LOG_ERR,"Unable to complete action");
                    $oess->_rollback();
                }
            }
	    
        }
    }
}

main();

