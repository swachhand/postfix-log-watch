#!/usr/bin/perl -w

=head1 NAME

postfix_log_watch.pl - Monitor postix log files

Authors(s) : Amit Tiwary [ amitt@one.com ]

=head1 SYNOPSIS

    postfix_log_watch.pl [--axed [count]][--bounced [count]] [--deferred [count]]
                         [--nrcpt [count]] [--pending [count]] [--sent [count]]
                         [--clear] [--domain] [--dump] [--load <file>] [--prow] [--quiet]
                         [--repeat [timeinmins]] [--rinse <timeinhours>] [--help] [[maillog1] [maillogN]]

    If no file(s) specified, reads from stdin.

=head1 DESCRIPTION

    postfix_log_watch.pl is a log watcher for the postfix. It is designed to
    provide an over-view of postfix activity, with just enough detail(s) to
    give the administrator a "heads up" for potential abuse.
    
    postfix_log_watch.pl watches postfix logs and periodically generates summaries
    of mail server traffic volumes (nrcpt, sent, bounced, rejected, deferred, etc).

=head1 OPTIONS

    --field [N]
           (where field=axed|bounced|deferred|nrcpt|pending|sent)
           lists N users with highest field count [N defaults to 10]

    --clear
            clear screen before performing action(s) (handy while using --repeat)

    --domain
           list results based on domain-name instead of e-mail(default)

    --dump
           dumps current state into a file for future use with --load

    --load < file >
           loads an old-state from qid-sender-status file (obtained via --dump)
           before processing current logs

    --prow
           populate filename(s) by appending current 'yyyymmdd' to cmd line arguments
           use this option to monitor logs that rotate every day

    --quiet
           supress all message(s) except error(s) and warning(s)

    --repeat [delay]
           repeat action(s) every delay mins [defaults to 5 mins]
           NOTE(s): while waiting press
                     [abdnps] to get top 20 entries sorted on respective field
                     'c' to set/unset --clear
                     'C' to over-rule delay and start next round of processing
                     'D' to perform immediate --dump
                     'N' to list number of entries in qid-sender and sender-status
                     'Q' to exit
                     'q' to set/unset --quiet
                     'R' to perform immediate --rinse
                    --dump used with --repeat creates a separate dump every delay mins

    --rinse <delay>
           removes entry of senders from sender-status who are inactive for delay hours
           with zero pending count [rinse is enabled by default and set to 8 hours]
           this elegantly controls the growth of sender-status which otherwise may
           become extremely large over a period of time with in-active sender information

    --help
           detailed usage


=head1 RETURN VALUE

    does not return anything of interest to the shell.

=head1 ERRORS

    Error/Warning messages are emitted to stderr.

=head1 NOTES

    File::Tail, File::Tail::Multi and Mail::Log::Parse::Postfix are not used
    due to extensibility constraints

    HoA is used to store mail queue-id and sender information

    %mailq_sender = (
        'qid1' => [sender1@domain1, nrcpt, sent, bounced],
        'qid2' => [sender2@domain2, nrcpt, sent, bounced]
    );

    %sender_status = (
        'sender1@domain1' => [total_nrcpt, total_sent, total_bounced, total_deferred, total_axed, nrcpt, sent, bounced, deferred, daxed, mtime],
        'sender2@domain2' => [total_nrcpt, total_sent, total_bounced, total_deferred, total_axed, nrcpt, sent, bounced, deferred, daxed, mtime],
    );

    There is no need to add support for time based options like:
        --time t1 [t2]
        --last Nmin
        --last Nhour

    This can be handled by extracting relevant lines using standard linux
    tools/utilities and piping it to postfix_log_watch.pl


=head1 REQUIREMENTS

    requires Getopt::Long, Term::ReadKey, Term::ANSIColor, Sort::Key::Top, Time::Local

=head1 LICENSE

    Free Software, Free Society!
 
    An on-line copy of the GNU General Public License can be found
    http://www.fsf.org/copyleft/gpl.html

=head1 TODO

    1) Improve --dump and --load so that it allows to dump current state and
       a) resume any time today (log files remain same)
       b) resume tomorrow (log files must have rotate)

    2) Load options/arguments from configuration file instead of cmd line
       --loadconfig <config_file>

    3) Dynamically load options/arguments from configuration file

=cut

use strict;
use warnings;

use Getopt::Long;

use Time::Local;
use POSIX qw(strftime);

use Term::ReadKey;
use Term::ANSIColor qw( colored );

#use Sort::Key::Top qw( rnkeytopsort );

use feature 'state';

# per-qid, per-sender, per-domain data, per-file-offset data
my ( %mailq_sender, %sender_status, %domain_status, %filename_offset );

# number of fields in HoA { k1 => [v1, v2, v3, v4, ... vN] }
# update this count if new column is added to HoA
my ( $max_fields_mailq_sender, $max_fields_sender_status ) = ( 4, 11 );

# default number of entries to display, repeat delay (in mins), rinse delay (in hours), inactive delay (in hours)
my ( $default_count, $default_on_demand_count, $default_repeat_delay, $default_rinse_delay, $max_inactive_delay ) = ( 10, 20, 5, 8, 24 );

# href to access %sender_status, %domain_status
my $href;

# start date that would be appended to name of log files
my $start_date_suffix;

# time stamp when --rinse was last invoked
my $last_rinse_time;

# (k,v) to quickly access status in %sender_status
my %status_index = ( 'dpending' => -2, 'pending' => -1, 
                     'nrcpt' => 0, 'sent' => 1, 'bounced' => 2, 'deferred' => 3, 'axed' => 4,
                     'dnrcpt' => 5, 'dsent' => 6, 'dbounced' => 7, 'ddeferred' => 8, 'daxed' => 9, 'mtime' => 10 );

my %mailq_index = ( 'sender' => 0, 'nrcpt' => 1, 'sent' => 2, 'bounced' => 3 );

# flag and flag-values
my %on_demand_flag_vals = ( a => ['daxed', 'axed'], b => ['dbounced', 'bounced'], d => ['ddeferred', 'deferred'],
                            n => ['dnrcpt','nrcpt'], p => ['dpending', 'pending'], s => ['dsent', 'sent'] );


# command line options
my ( $help, $amax, $bmax, $dmax, $nmax, $pmax, $smax, $clear, $dumptofile, $ondomain, $prow, $quiet, $repeat_delay, $rinse, $load_file );

# parse options and arguments
usage() unless GetOptions( 'help' => \$help,
                           'axed:i' => \$amax, 'bounced:i' => \$bmax, 'deferred:i' => \$dmax, 'nrcpt:i' => \$nmax,
                           'pending:i' => \$pmax, 'sent:i' => \$smax,
                           'clear' =>\$clear, 'dump' => \$dumptofile, 'domain' => \$ondomain, 'prow' => \$prow, 'quiet' => \$quiet, 
                           'repeat:i' => \$repeat_delay, 'rinse=i' => \$rinse, 
                           'load=s'=> \$load_file
                         );

detailed_usage() if defined($help);

# if --prow used without cmd line arguments, ignore it
undef($prow) if( defined($prow) && !(@ARGV) );

# set default repeat delay for values outside the range [5m,1h] 
$repeat_delay = $default_repeat_delay if ( defined($repeat_delay) && ( ($repeat_delay < 5) || ($repeat_delay > 60) ) );

# set default rinse delay for values outside the range [1h,12h] 
$rinse = $default_rinse_delay if ( !defined($rinse) || ($rinse < 1) || ($rinse > 12) );

# current time stamp becomes last_rinse_time
$last_rinse_time = time();

# load dumped old-state before processing log files
load_dump_from_file( $load_file ) if ( $load_file );

# generate logfilename and record filename along with their initial-offset to read from
if ( defined($prow) ) {
    $start_date_suffix = strftime( "%Y%m%d", localtime );

    foreach my $arg_num (0 .. $#ARGV) {
        $filename_offset{ $ARGV[$arg_num] . $start_date_suffix } = 0;
    }
}
else {
    # record log-files to process and their initial-offset to read from
    foreach my $arg_num (0 .. $#ARGV) {
        $filename_offset{ $ARGV[$arg_num] } = 0;
    }
}

# prcoess all log files and perform action(s) as per cmd-line-options
do {
    if ( defined($clear) ) {
        print "\033[2J";    #clear the screen
        print "\033[0;0H";  #jump to 0,0
    }

    clear_delta_status();

    process_day_change( \%filename_offset ) if ( defined($prow) );

    (@ARGV) ? process_files( \%filename_offset ) : process_log_lines( 'STDIN' );

    # populate domain_status on the fly
    if ( defined($ondomain) ) {
        create_domain_status();
        $href = \%domain_status;
    }
    else {
        $href = \%sender_status;
    }

    if ( defined($amax) ) {
        display_sender_status('daxed', $amax);
        display_sender_status('axed', $amax);
    }
    if ( defined($bmax) ) {
        display_sender_status('dbounced', $bmax);
        display_sender_status('bounced', $bmax);
    }
    if ( defined($dmax) ) {
        display_sender_status('ddeferred', $dmax);
        display_sender_status('deferred', $dmax);
    }
    if ( defined($nmax) ) {
        display_sender_status('dnrcpt', $nmax);
        display_sender_status('nrcpt', $nmax);
    }
    if ( defined($pmax) ) {
        display_sender_status('dpending', $pmax);
        display_sender_status('pending', $pmax);
    }
    if ( defined($smax) ) {
        display_sender_status('dsent', $smax);
        display_sender_status('sent', $smax);
    }

    if ( defined($rinse) ) {
        rinse_sender_status();
    }

    if ( defined($dumptofile) ) {
        save_dump_to_file();
    }
 
} while ( defined($repeat_delay) && mysleep(60 * $repeat_delay) );

# all function/sub

sub usage
{
    my ($no_exit) = (@_);

    print "usage: " . __FILE__ . "\n\t[--axed [count]] [--bounced [count]] [--deferred [count]]".
                                 "\n\t[--nrcpt [count]] [--pending [count]] [--sent [count]]".
                                 "\n\t[--clear] [--domain] [--dump] [--load <file>] [--prow] [--quiet]".
                                 "\n\t[--repeat [timeinmins]] [--rinse <timeinhours>] [--help] [[maillog1] [maillogN]]\n\n".
                                 "\n\tIf no file(s) specified, reads from stdin\n\n";

    exit unless( defined($no_exit) );
}

sub detailed_usage
{
    usage( 'no_exit' );
    print "\t--field [N]     : (where field=axed|bounced|deferred|nrcpt|pending|sent) lists N users with \n".
          "\t                  highest field count [N defaults to 10]\n\n".
          "\t--clear         : clear screen before performing action(s) (handy while using --repeat)\n\n".
          "\t--domain        : list results based on domain-name instead of e-mail(default)\n\n".
          "\t--dump          : dumps current state into a file for future use with --load\n\n".
          "\t--load <file>   : loads an old-state from qid-sender-status file (obtained via --dump)\n".
          "\t                  before processing current logs\n\n".
          "\t--prow          : populate filename(s) by appending current 'yyyymmdd' to cmd line arguments\n".
          "\t                  use this option to monitor logs that rotate every day\n\n".
          "\t--quiet         : supress all message(s) except error(s) and warning(s)\n\n".
          "\t--repeat [time] : repeat action(s) every time mins [defaults to 5 mins]\n".
          "\t                  NOTE(s): while waiting press\n".
          "\t                    [abdnps] to get top 20 entries sorted on respective field\n".
          "\t                    'c' to set/unset --clear\n".
          "\t                    'C' to over-rule delay and start next round of processing\n".
          "\t                    'D' to perform --dump\n".
          "\t                    'N' to list number of entries in qid-sender and sender-status\n".
          "\t                    'Q' to exit\n".
          "\t                    'q' to set/unset --quiet\n".
          "\t                    'R' to perform --rinse\n".
          "\t                    --dump used with --repeat creates a separate dump every delay mins\n\n".
          "\t--rinse <delay> : removes entry of senders from sender-status who are inactive for delay hours\n".
          "\t                  with zero pending count [rinse is enabled by default and set to 8 hours]\n".
          "\t                  this elegantly controls the growth of sender-status which otherwise may\n".
          "\t                  become extremely large over a period of time with in-active sender information\n\n".
          "\t--help          : detailed usage\n\n";

    exit;
}

# takes pair(s) of (word,regex) and for every pair returns portion of word that matches regex
# example: get_matched_string('pdf2txt','(/d)') returns 2
sub get_matched_string {
   my ($aref) = @_;
   my @ret_words;

   while (my ($word, $regex) = splice(@$aref, 0, 2) ) {

      if ( $word =~ /$regex/ ) {
          push(@ret_words, $1);
      }
      else {
          return @ret_words;
      }
   }

   return @ret_words;
}

# prcoess lines of smtp log line(s) and build/update %mailq_sender and %sender_status
sub process_log_lines {
    my ($fh) = (@_);

    while( my $line = <$fh> ) {

        my @words = split(/\s+/,$line);

        # real activity starts from field 5
        # Sep  2 00:00:01 csmtp16 postfix...
        for my $i (4 .. $#words) {

            # smtp - status
            # Sep  2 01:09:45 csmtp16 postfix-yahoo/smtp[60274]: 0850740000B94: to=<trbont@yahoo.com>, relay=mta7.am0.yahoodns.net[98.136.216.26]:25, delay=13305, delays=13287/15/1.2/2.1, dsn=2.0.0, status=sent (250 ok dirdel 2/0)
            if( $words[$i] =~ /^postfix.+smtp\[/ ) {
                my ($qid, $status) = get_matched_string( [ $words[$i+1],'([0-9A-F]+):$',
                                                           $words[$i+7],'^status=([a-z]+)' ] )
                    if ( defined($words[$i+1]) && defined($words[$i+7]) );

                # handle corner-cases where status= is not at index $i+7
                if ( defined($qid) && !defined($status) ) {
                    $status = $1 if ( $line =~ /status=([a-z]+)/ );
                }

                if ( defined($qid) && defined($status) && defined($status_index{$status}) &&
                     ($status_index{$status} > 0) && ($status_index{$status} < 4) ) {
                    my $sender = $mailq_sender{$qid}[$mailq_index{'sender'}]
                        if ( exists($mailq_sender{$qid}) && defined($mailq_sender{$qid}[$mailq_index{'sender'}]) );

                    if ( defined($sender) && exists($sender_status{$sender}[$status_index{$status}]) ) {
                        ++$sender_status{$sender}[$status_index{$status}];
                        ++$sender_status{$sender}[$status_index{'d'.$status}];

                        # update sent/bounced status in mailq_sender
                        ++$mailq_sender{$qid}[$mailq_index{$status}] if ( exists($mailq_index{$status}) );

                        $sender_status{$sender}[$status_index{'mtime'}] = $words[0].' '.$words[1].' '.$words[2];
                    }
                }
                last;
            }

            # qmgr - nrcpt, sender, removed
            # Sep  2 00:04:27 csmtp16 postfix/qmgr[14940]: 05BF6400008F8: from=<team@gtmusicawards.com>, size=3840, nrcpt=50 (queue active)
            # Sep  2 23:59:07 csmtp16 postfix/qmgr[14940]: D9AE740000B89: removed
            if( $words[$i] =~ /^postfix.+qmgr\[/ ) {
                my ($qid, $sender, $nrcpt);

                if ( defined($words[$i+2]) && ($words[$i+2] eq 'removed') ) {
                    ($qid) = get_matched_string( [ $words[$i+1],'([0-9A-F]+):$' ] ) if ( defined($words[$i+1]) );
                    delete $mailq_sender{$qid} if (defined($qid) && exists($mailq_sender{$qid}) );
                    last;
                }
                else {
                    ($qid, $sender, $nrcpt) = get_matched_string( [ $words[$i+1],'([0-9A-F]+):$',
                                                                    $words[$i+2],'^from=<([^>]+)>,',
                                                                    $words[$i+4],'^nrcpt=(\d+)' ] )
                        if ( defined($words[$i+1]) && defined($words[$i+2]) && defined($words[$i+4]) );
                }

                if ( defined($qid) && defined($sender) && defined($nrcpt) ) {

                    if ( exists($mailq_sender{$qid})) {
                        last;
                    }
                    else {
                        @{$mailq_sender{$qid}} = ($sender, $nrcpt, 0, 0);
                    }

                    if ( !exists($sender_status{$sender}) ) {
                        @{$sender_status{$sender}} = ($nrcpt, 0, 0, 0, 0, $nrcpt, 0, 0, 0, 0);
                    }
                    else {
                        $sender_status{$sender}[$status_index{'nrcpt'}] += $nrcpt;
                        $sender_status{$sender}[$status_index{'dnrcpt'}] += $nrcpt;
                    }

                    $sender_status{$sender}[$status_index{'mtime'}] = $words[0].' '.$words[1].' '.$words[2];
                }
                last;
            }

            # requeued with new qid
            # 8 09:12:14 csmtp8 postfix/pickup[7726]: 07A7FC000EC98: uid=102 from=<rps@rpscatering.no> orig_id=73B838095EFF8
            if( $words[$i] =~ /^postfix.+pickup\[/ ) {
                my ($newqid, $sender, $oldqid) = get_matched_string( [ $words[$i+1],'([0-9A-F]+):$',
                                                                       $words[$i+3],'^from=<([^>]+)>',
                                                                       $words[$i+4],'([0-9A-F]+)' ] )
                    if ( defined($words[$i+1]) && defined($words[$i+3]) && defined($words[$i+4]) );

                if ( defined($newqid) && defined($sender) && defined($oldqid) && exists($mailq_sender{$oldqid}) ) {
                    my $num_pending = $mailq_sender{$oldqid}[1]-$mailq_sender{$oldqid}[2]-$mailq_sender{$oldqid}[3];

                    $sender_status{$sender}[$status_index{'nrcpt'}] -= $num_pending;
                    $sender_status{$sender}[$status_index{'dnrcpt'}] -= $num_pending;

                    $sender_status{$sender}[$status_index{'mtime'}] = $words[0].' '.$words[1].' '.$words[2];

                    delete ($mailq_sender{$oldqid}); 
                }
                last;
            }

            # postsuper removal - axed senders
            # csmtp11/mail-20140908:Sep  8 07:41:46 csmtp11 postfix/postsuper[100461]: ABDFC400058EC: removed
            if( $words[$i] =~ /^postfix.+postsuper\[/ ) {
                if ( defined($words[$i+1]) && defined($words[$i+2]) && ($words[$i+2] eq 'removed') ) {
                    my ($qid) = get_matched_string( [ $words[$i+1],'([0-9A-F]+):$' ] );

                    if ( defined($qid) && exists($mailq_sender{$qid}) ) {

                        my $sender = $mailq_sender{$qid}[$mailq_index{'sender'}];

                        my $num_pending = $mailq_sender{$qid}[$mailq_index{'nrcpt'}] -
                                          $mailq_sender{$qid}[$mailq_index{'sent'}] -
                                          $mailq_sender{$qid}[$mailq_index{'bounced'}];

                        $sender_status{$sender}[$status_index{'axed'}] += $num_pending;
                        $sender_status{$sender}[$status_index{'daxed'}] += $num_pending;

                        $sender_status{$sender}[$status_index{'mtime'}] = $words[0].' '.$words[1].' '.$words[2];

                        delete ($mailq_sender{$qid}); 
                    }
                }
                last;
            }

        } # for
    } # while
}

# read log files and records last-read-offset for future reads
sub process_files {
    my ($r_filename_offset) = (@_);

    foreach my $filename ( keys %{$r_filename_offset} ) {

        my $fh;
        if ( !open( $fh => $filename) ) {
            warn "cannot open [ $filename ]: $!";
            next;
        }

        seek($fh, $r_filename_offset->{$filename}, 0); # seek to last-read offset

        print "reading [ $filename ]\n" unless defined($quiet);
        process_log_lines( $fh );

        $r_filename_offset->{$filename} = tell($fh);

        close($fh) || warn "close failed for $filename : $!";
    }
}

# populate %domain_status by prcoessing %sender_status
sub create_domain_status {
    %domain_status = ();

    while ( (my $key, my $value) = each(%sender_status) ) {

        my ($new_key) = $key =~ /.*@(.*)/;

        if ( exists($domain_status{$new_key}) ) {
            for my $i ( 0 .. $#{$value}-1 ) {
                $domain_status{$new_key}[$i] += @{$value}[$i];
            }
        }
        else {
            $domain_status{$new_key} = [ @{$value} ];
        }
    }
}

# display stats from $href sorted on a field specified by user
sub display_sender_status {
    my ($sortby, $num) = (@_);
    
    my $index = $status_index{$sortby} // 0;
    $num = $default_count if ( $num <= 0 );

    printf "%44s %38s|%38s\n",colored($sortby, 'yellow'),'|<----------- Total Count ----------->','<-------- Last N mins Count -------->|'; 
    printf "%35s %6s %6s %6s %5s %5s %5s|%6s %6s %6s %5s %5s %5s\n",
           'Sender','nrcpt','pend','sent','bncd','defrd','axed','nrcpt','pend','sent','bncd','defrd','daxed';
    printf "%35s %6s %6s %6s %5s %5s %5s|%6s %6s %6s %5s %5s %5s\n",
           '------','-----','----','----','----','-----','----','-----','----','----','----','-----','-----';

    #my @top_keys;
    my @sorted_keys;

    if ( $index == -1 ) {
        my ($ni, $si, $bi, $ai) = ( $status_index{'nrcpt'}, $status_index{'sent'}, $status_index{'bounced'}, $status_index{'axed'} );
        #(@top_keys) = rnkeytopsort { ($href->{$_}[$ni]-$href->{$_}[$si]-$href->{$_}[$bi]-$href->{$_}[$ai]) } $num => keys %$href;
        (@sorted_keys) = sort { ($href->{$b}[$ni]-$href->{$b}[$si]-$href->{$b}[$bi]-$href->{$b}[$ai]) <=>
                                ($href->{$a}[$ni]-$href->{$a}[$si]-$href->{$a}[$bi]-$href->{$a}[$ai]) } keys %$href;
    }
    elsif ( $index == -2 ) {
        my ($ni, $si, $bi, $ai) = ( $status_index{'dnrcpt'}, $status_index{'dsent'}, $status_index{'dbounced'}, $status_index{'daxed'} );
        #(@top_keys) = rnkeytopsort { ($href->{$_}[$ni]-$href->{$_}[$si]-$href->{$_}[$bi]-$href->{$_}[$ai]) } $num => keys %$href;
        (@sorted_keys) = sort { ($href->{$b}[$ni]-$href->{$b}[$si]-$href->{$b}[$bi]-$href->{$b}[$ai]) <=>
                                ($href->{$a}[$ni]-$href->{$a}[$si]-$href->{$a}[$bi]-$href->{$a}[$ai]) } keys %$href;
    }
    else {
        #(@top_keys) = rnkeytopsort { $href->{$_}[$index] } $num => keys %$href;
        (@sorted_keys) = sort { $href->{$b}[$index] <=> $href->{$a}[$index] } keys %$href;
    }

    #for my $sender ( @top_keys ) {
    for my $sender ( @sorted_keys ) {

        last if ( $num-- <= 0 );
        my($f1, $f2, $f3, $f4, $f5, $f6, $f7, $f8, $f9, $f10) = @{$href->{$sender}};

        # pending = nrcpt-sent-bounced-axed
        printf "%35s %6s %6s %6s %5s %5s %5s|%6s %6s %6s %5s %5s %5s\n",
                $sender, $f1, ($f1-$f2-$f3-$f5), $f2, $f3, $f4, $f5, $f6, ($f6-$f7-$f8-$f10), $f7, $f8, $f9, $f10;
    }

    print "\n";
}

# dump %mailq_sender and %sender_status to file
sub save_dump_to_file {
    my $date_time_string = strftime "%Y%m%d%H%M%S", localtime;
    my $qss_file = 'qid-sender-status' . $date_time_string;

    my $qss_handle;
    open ($qss_handle, '>', $qss_file ) || die "cannot open $qss_file : $!\n";

    printf "dumping to file [ $qss_file ] " unless( defined($quiet));

    while ( (my $key, my $value) = each(%mailq_sender) ) {
        print $qss_handle "$key @{$value}\n";
    }

    print $qss_handle "END\n";

    while ( (my $key, my $value) = each(%sender_status) ) {
        print $qss_handle "$key @{$value}\n";
    }

    printf " [OK]\n" unless( defined($quiet));

    close( $qss_handle ) || warn "cannot close $qss_file : $!\n";
}

# build %mailq_sender and %sender_status by reading dump file
sub load_dump_from_file {
    my ($qss_file) = (@_);
    my $qss_handle;

    open ($qss_handle, '<', $qss_file ) || die "cannot open $qss_file : $!\n";

    printf "loading qid-sender-status from file [ $qss_file ]\n" unless defined($quiet);

    my $parse_error = 0;
    my $line;
    while( !($parse_error) && ($line = <$qss_handle>) ) {

        chomp($line);
        last if ( $line eq 'END' );

        my @words = split(/\s+/,$line);

        my ( $qid, $sender ) = get_matched_string( [ $words[0],'([A-Z0-9]+)', $words[1],'(.+@.*)' ] )
            if ( $#words ==  $max_fields_mailq_sender );

        if ( defined($qid) && defined($sender) ) {
            push( @{$mailq_sender{$qid}}, $sender);

            for my $i (2 .. $#words) {

                my ($num) = get_matched_string( [ $words[$i],'(\d+)' ] ) if ( defined($words[$i]) );

                if ( defined($num) ) {
                    push( @{$mailq_sender{$qid}}, $num);
                }
                else {
                    $parse_error = 1;
                    last;
                }
            }
        }
        else {
            $parse_error = 1;           
        }
    }

    while( !($parse_error) && ($line = <$qss_handle>) ) {

        chomp($line);
        my @words = split(/\s+/,$line);

        my ( $sender ) = get_matched_string( [ $words[0],'(.+@.*)' ] ) if ( $#words == $max_fields_sender_status + 2 );

        if ( defined($sender) ) {
            for my $i (1 .. ($#words - 3)) {

                my ($num) = get_matched_string( [ $words[$i],'(\d+)' ] ) if ( defined($words[$i]) );

                if ( defined($num) ) {
                    push( @{$sender_status{$sender}}, $num);
                }
                else {
                    $parse_error = 1;
                    last;
                }
            }

            # get last 3 fields and validate against Mon dd hh:mm:ss
            my $date_str = $words[$#words-2] . ' ' . $words[$#words-1] . ' ' . $words[$#words];

            if ( get_matched_string( [ $date_str, '([A-Z][a-z][a-z] \d+ \d\d:\d\d:\d\d)' ] ) ) {
                push( @{$sender_status{$sender}}, $date_str );
            }
            else {
                print "error parsing date...\n";
                $parse_error = 1;
            }
        }
        else {
            $parse_error = 1;
        }
    }

    if ( $parse_error ) {
        %mailq_sender = ();
        %sender_status = ();

        warn "[$qss_file] error parsing line: $line\n";
    }

    close( $qss_handle ) || warn "cannot close $qss_file : $!\n";
}

# clear delta status (dnrcpt, dsent, etc) in %sender_status
sub clear_delta_status {
    my ($ni, $si, $bi, $di, $ai) = ( $status_index{'dnrcpt'}, $status_index{'dsent'}, $status_index{'dbounced'},
                                     $status_index{'ddeferred'}, $status_index{'daxed'}  );

    foreach my $sender ( keys %sender_status ) {

        $sender_status{$sender}[$ni] = $sender_status{$sender}[$si]
            = $sender_status{$sender}[$bi] = $sender_status{$sender}[$di]
                = $sender_status{$sender}[$ai] = 0;
    }

    foreach my $domain ( keys %domain_status ) {

        $domain_status{$domain}[$ni] = $domain_status{$domain}[$si]
            = $domain_status{$domain}[$bi] = $domain_status{$domain}[$di]
                = $domain_status{$domain}[$ai] = 0;
    }
}

# sleep and wait for on-demand-flags
sub mysleep {
    my ($delay) = (@_);
    
    eval {
        local $SIG{ALRM} = sub {  die "wakeup\n" };

        alarm $delay;
        ReadMode('raw');

        while (1) {

            my $on_demand_flag = ReadKey($delay);

            if ( defined($on_demand_flag) ) {

                if( $on_demand_flag && exists($on_demand_flag_vals{$on_demand_flag}) ) {
                    display_sender_status($on_demand_flag_vals{$on_demand_flag}[0], $default_on_demand_count);
                    display_sender_status($on_demand_flag_vals{$on_demand_flag}[1], $default_on_demand_count);
                }
                elsif( $on_demand_flag eq 'c' ) {
                 ( defined $clear ) ? undef($clear) : $clear = 1;
                }
                elsif( $on_demand_flag eq 'C' ) {
                 alarm 0;
                 last;
                }
                elsif( $on_demand_flag eq 'D' ) {
                    save_dump_to_file();
                }
                elsif( $on_demand_flag eq 'N' ) {
                    print 'number of entries in [ qid-sender , sender-status ] = [ '.
                          scalar(keys %mailq_sender) . ' , ' . scalar(keys %sender_status) . " ]\n";
                }
                elsif( $on_demand_flag eq 'Q' ) {
                    ReadMode('restore');
                    exit;
                }
                elsif( $on_demand_flag eq 'q' ) {
                 ( defined $quiet ) ? undef($quiet) : $quiet = 1;
                }
                elsif( $on_demand_flag eq 'R' ) {
                    rinse_sender_status( 'forced' );
                }
            }
        }
    };

    ReadMode('restore');
    return 1;
}

# check for change in date and take appropriate action
sub process_day_change {
    my ( $r_filename_offset ) = (@_);

    state $old_suffix = $start_date_suffix;
    my $new_suffix = strftime( "%Y%m%d", localtime );

    if ( $new_suffix ne $old_suffix ) {
        foreach my $arg_num (0 .. $#ARGV) {

            my ( $old_filename, $new_filename ) = ( $ARGV[$arg_num] . $old_suffix, $ARGV[$arg_num] . $new_suffix );

            # process old-file and replace its entry with new-file in %filename_offset
            if ( exists($r_filename_offset->{ $old_filename }) && !exists($r_filename_offset->{ $new_filename }) ) {
                process_files( { $old_filename => $r_filename_offset->{ $old_filename } } );

                delete $r_filename_offset->{ $old_filename };
                $r_filename_offset->{ $new_filename } = 0;
            }
        }
        $old_suffix = $new_suffix;
    }
}

sub rinse_sender_status {
    my ( $forced ) = (@_);

    if ( $forced || ( ( time() - $last_rinse_time ) >= ($rinse * 60 * 60 ) )  ) {
        print "last rinse was performed on " . localtime( $last_rinse_time ) . "\n";

        $last_rinse_time = time();

        my @to_delete;

        # timelocal takes month-number starting from 0 and year-1900
        my %months = ( Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5, Jul => 6,
                       Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11 );

        foreach my $sender ( keys %sender_status ) {

            my ($mon, $dd, $hour, $min, $sec) = split( /[: ]+/, $sender_status{$sender}[$status_index{'mtime'}] );
            $mon = $months{$mon};

            my $year =  (localtime)[5];
            my $sender_mtime = timelocal( $sec, $min, $hour, $dd, $mon, $year);

            if ( $sender_mtime > $last_rinse_time ) {
                # get correct sender_mtime with $year-1
                $sender_mtime = timelocal( $sec, $min, $hour, $dd, $mon, $year-1);
            }

            # record inactive senders with pending count <= 0
            if( (($last_rinse_time - $sender_mtime) >= ($rinse * 60 * 60)) &&
                 (($sender_status{$sender}[$status_index{'nrcpt'}] - $sender_status{$sender}[$status_index{'sent'}] -
                   $sender_status{$sender}[$status_index{'bounced'}] - $sender_status{$sender}[$status_index{'axed'}]) <= 0 )) {
                push( @to_delete, $sender );
            }
            # record senders that are inactive for day(s) [do not care about pending count]
            elsif ( ($last_rinse_time - $sender_mtime) >= ($max_inactive_delay * 60 * 60) ) {
                push( @to_delete, $sender );
            }
        }

        delete @sender_status{ @to_delete };
    }
}

