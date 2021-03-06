#!/usr/bin/perl

use strict;
use warnings;

use OESS::User;
use OESS::Interface;

package OESS::DB::Workgroup;

=head2 fetch
=cut
sub fetch{
    my %params = @_;
    my $db = $params{'db'};
    my $workgroup_id = $params{'workgroup_id'};
    
    my $wg = $db->execute_query("select * from workgroup where workgroup_id = ?",[$workgroup_id]);
    if(!defined($wg) || !defined($wg->[0])){
        return;
    }
    
    my @ints;
    my $interfaces = $db->execute_query("select interface_id from interface where workgroup_id = ?",[$workgroup_id]);
    $wg->[0]->{'interfaces'} = $interfaces;
    
    return $wg->[0];
}

=head2 get_users_in_workgroup
=cut
sub get_users_in_workgroup{
    my %params = @_;
    
    my $db = $params{'db'};
    my $workgroup_id = $params{'workgroup_id'};
    
    my $users = $db->execute_query("select user_id from user_workgroup_membership where workgroup_id = ?",[$workgroup_id]);
    if(!defined($users)){
        return;
    }
    
    my @users;
    
    foreach my $u (@$users){
        my $user = OESS::User->new(db => $db, user_id => $u->{'user_id'});
        if(!defined($user)){
            next;
        }
        
        push(@users, $user);
    }
    return \@users;
}

1;
