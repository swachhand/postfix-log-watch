============================================
postfix-log-watch : Monitor postix log files
============================================

Synopsis
========

    postfix_log_watch.pl [--axed [count]][--bounced [count]] [--deferred [count]]
                         [--nrcpt [count]] [--pending [count]] [--sent [count]]
                         [--clear] [--domain] [--dump] [--load <file>] [--prow] [--quiet]
                         [--repeat [timeinmins]] [--rinse <timeinhours>] [--help] [[maillog1] [maillogN]]

    If no file(s) specified, reads from stdin.

Description
===========

  postfix_log_watch.pl is a log watcher for the postfix. It is designed to provide an over-view of postfix activity, with just enough detail(s) to give the administrator a "heads up" for potential abuse. This utility watches postfix logs and periodically generates summaries of mail server traffic volumes (nrcpt, sent, bounced, rejected, deferred, etc).

Options
=======

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

Return value
============

  Does not return anything of interest to the shell.

Errors
======

  Error/Warning messages are emitted to stderr.

Notes
=====
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


Requirements
============

  Requires Getopt::Long, Term::ReadKey, Term::ANSIColor, Sort::Key::Top, Time::Local

Licnse
=======
  
  Free Software, Free Society!
  An on-line copy of the GNU General Public License can be found at http://www.fsf.org/copyleft/gpl.html

To-Do
=====

  1) Improve --dump and --load so that it allows to dump current state and a) resume any time today (log files remain same) b) resume tomorrow (log files must have rotate)
  
  2) Load options/arguments from configuration file instead of cmd line
     --loadconfig <config_file>
     
  3) Dynamically load options/arguments from configuration file
