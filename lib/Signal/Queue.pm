
=encoding utf-8

=head1 NAME

B<Signal::Queue> - POSIX signals as a queue

=head1 SYNOPSIS

    #!perl
    use Signal::Queue qw( sig_init sig_next );

    sig_init( 'HUP' );
    printf "Hup %s five times!\n", $$;
    printf "%s %s\n", $_, sig_next() for 1 .. 5;
    printf "%s so hapi!\n", $$;

=head1 DESCRIPTION

B<Signal::Queue> implements a queue of received POSIX signals.

The motivating use case for this module is an event loop that handles one signal
per iteration and blocks while there are no signals to handle.
If you want to handle signals in your event loop without blocking, it still
presents a friendly API.
However in this case you should also consider sticking to just %SIG and flag
variables or an array.

It lets you specify which signals you want to handle through its interface and
stays out of the way of all other signals.

The queue holds at most one entry for a given signal at a given time.
Additional deliveries of signals already present in the queue are simply
dropped.
By this mechanism we avoid uncontrolled growing of the queue when signals are
recieved faster than they're handled.

This dropping of duplicate signals does not pose any additional burden on
callers compared to other ways of handling POSIX signals.
The OS itself already coalesces multiple generated signals of the same type into
a single delivery.

Throughout this module, signals are named as they appear in the C<sig_name>
property of the L<Config> core module.

=cut

package Signal::Queue;
use 5.008001;
use strict;
use warnings;
use utf8;

use Carp qw( confess croak );
use Config;
use Exporter qw( import );
use POSIX;

our $VERSION = "0.01";

our @EXPORT_OK = qw(
  sig_deinit
  sig_ignore
  sig_init
  sig_next
  sig_ready
);
our %EXPORT_TAGS = ( all => [@EXPORT_OK] );
Exporter::export_ok_tags('all');

my $SIGSET;
my %OLD_ACTIONS;
my %SIG_NUMS;
my @QUEUE;
my @SIG_NAMES;
my $IGNORE = POSIX::SigAction->new( &POSIX::SIG_IGN );
my $HANDLER;

if ( $Config{sig_name} && $Config{sig_num} ) {
    @SIG_NAMES = split ' ', $Config{sig_name};
    @SIG_NUMS{@SIG_NAMES} = split ' ', $Config{sig_num};
}

=head1 SUBROUTINES

=head2 sig_init LIST,HASHREF

=head2 sig_init LIST

Initialize the queue.

    sig_init( 'HUP', 'TERM', { sa_flags => 0 } );

Configures signal handlers for the given signals.

Takes a list of signal names, with an extra last argument that is a hashref of
options.

The option C<sa_flags> is an integer of bitflags corresponding to the
C<sa_flags> argument of the C<sigaction> POSIX system call.
These flags are available as constants prefixed by C<SA_> in the L<POSIX>
module.
The default value is C<0>.

Throws an exception if signal information is not available in the L<Config>
module,
if already initialized, or
if called with an unrecognized argument.

=cut

sub sig_init {
    my @sig_names = @_;
    my %options;
    %options = %{ pop @sig_names }
      if ref $sig_names[$#sig_names] eq 'HASH';
    my $sa_flags = delete $options{sa_flags} // 0;

    croak "no signals?"
      if !@SIG_NAMES;
    confess "already initialized"
      if $SIGSET;
    confess "unexpected option(s)" . join( ' ', sort keys %options )
      if %options;
    if ( my @bad_names = grep { !exists $SIG_NUMS{$_} } @sig_names ) {
        confess "unrecognized signal name: " . join( ' ', @bad_names );
    }

    $sa_flags |= &POSIX::SA_SIGINFO;

    my @sig_nums = map { $SIG_NUMS{$_} } @sig_names;

    my $sig_set = POSIX::SigSet->new(@sig_nums);
    $HANDLER = POSIX::SigAction->new( \&_handler, $sig_set, $sa_flags );
    $HANDLER->safe(0);

    for my $sig_num (@sig_nums) {
        my $old_action = {};
        POSIX::sigaction( $sig_num, $HANDLER, $old_action );
        $OLD_ACTIONS{$sig_num} = $old_action;
    }

    $SIGSET = $sig_set;

    return;
}

=head2 sig_next

Wait for a signal.

    my $sig_name = sig_next();
    print "signal: $sig_name\n";

Blocks the calling thread until there is at least one signal in the queue.
The first signal is then removed from the queue and returned;

Throws an exception if not initialized.

=cut

sub sig_next {
    confess "not initialized"
      if !$SIGSET;

    my $old_sig_set = POSIX::SigSet->new();
    POSIX::sigprocmask( &POSIX::SIG_BLOCK, $SIGSET, $old_sig_set );

    POSIX::sigsuspend($old_sig_set)
      while !@QUEUE;

    my $sig_num = shift @QUEUE;
    sigaction( $sig_num, $HANDLER );

    POSIX::sigprocmask( &POSIX::SIG_SETMASK, $old_sig_set );

    return $SIG_NAMES[$sig_num];
}

=head2 sig_ready

Test if the queue is empty.

    if ( sig_ready() ) {
        my $sig_name = sig_next()
        print "signal: $sig_name\n";
    }
    else {
        print "no signal\n";
    }

Throws an exception if not initialized.

=cut

sub sig_ready {
    confess "not initialized"
      if !$SIGSET;

    return !!@QUEUE;
}

=head2 sig_ignore SIGNAME
X<sig_ignore>

Prevents a signal from being extracted.

    sig_ignore( 'TERM' );

Takes a single argument that is a signal name.

After this call, the given signal is never returned by L<C<sig_next>|/sig_next> again.

Throws an exception if not initialized, or
if the given signal is not among the ones given to L<C<sig_init>|/sig_init LIST>.

=cut

sub sig_ignore {
    my ($sig_name) = @_;

    confess "not initialized"
      if !$SIGSET;

    my $sig_num = $SIG_NUMS{$sig_name};
    confess "unexpected signal name"
      if !$SIGSET->ismember($sig_num);

    sigaction( $sig_num, $IGNORE );

    my $old_sig_set = POSIX::SigSet->new();
    POSIX::sigprocmask( &POSIX::SIG_BLOCK, $SIGSET, $old_sig_set );
    @QUEUE = grep { $_ != $sig_num } @QUEUE;
    POSIX::sigprocmask( &POSIX::SIG_SETMASK, $old_sig_set );

    return;
}

=head2 sig_deinit

Deinitialize the queue.

    my @remaining = sig_deinit();

Restores signal handlers for the signals given to L<C<sig_init>|/sig_init LIST>.

Any remaining signals are extracted from the queue and returned.

Throws an exception if not initialized.

=cut

sub sig_deinit {
    confess "not initialized"
      if !$SIGSET;

    for my $sig_num ( sort keys %OLD_ACTIONS ) {
        my $href = delete $OLD_ACTIONS{$sig_num};
        my $old_action =
          POSIX::SigAction->new( $href->{HANDLER}, $href->{MASK}, $href->{FLAGS} );
        $old_action->safe( $href->{SAFE} );
        POSIX::sigaction( $sig_num, $old_action );
    }

    $SIGSET  = undef;
    $HANDLER = undef;

    return splice @QUEUE;
}

sub _handler {
    my ( undef, $siginfo ) = @_;

    my $sig_num = $siginfo->{signo};
    sigaction( $sig_num, $IGNORE );
    push @QUEUE, $sig_num;
    return;
}

1;

__END__

=head1 EXAMPLES

Here's a complete example of a master process main loop driven by Signal::Queue.
It spawns a new worker every five seconds and reaps their exit statuses as they
terminate.

Send it SIGTERM to make it stop spawing new workers and exit once the last
worker has terminated.
Send it SIGQUIT to make it force shutdown by sending SIGTERM to all the active
workers.

    #!perl
    use Signal::Queue qw( sig_init sig_next sig_ignore );
    use POSIX;

    print "M $$: master starting\n";
    POSIX::setsid();
    sig_init( 'ALRM', 'CHLD', 'TERM', 'QUIT' );
    kill ALRM => $$;
    my $active = 1;
    my $kids   = 0;
    while ( $active || $kids > 0 ) {
        print "M $$: number of workers: $kids\n";
        my $sig_name = sig_next();
        if ( $sig_name eq 'ALRM' ) {
            print "M $$: ALRM\n";
            alarm(5);
            my $pid = fork // die "fork: $!";
            if ( $pid == 0 ) {
                $SIG{TERM} = 'DEFAULT';
                my $seconds = int( rand(15) ) + 3;
                print "w $$: worker starting ($seconds seconds)\n";
                sleep $seconds;
                print "w $$: worker done\n";
                exit 0;
            }
            $kids++;
        }
        elsif ( $sig_name eq 'CHLD' ) {
            print "M $$: CHLD\n";
            while ( ( my $child = waitpid( -1, &POSIX::WNOHANG ) ) > 0 ) {
                print "M $$: worker $child: status $?\n";
                $kids--;
            }
        }
        elsif ( $sig_name eq 'TERM' ) {
            print "M $$: TERM\n";
            sig_ignore('ALRM');
            $active = 0;
        }
        elsif ( $sig_name eq 'QUIT' ) {
            print "M $$: QUIT\n";
            sig_ignore('ALRM');
            sig_ignore('TERM');
            kill TERM => 0;
            $active = 0;
        }
    }
    print "M $$: master done\n";

=head1 LICENSE

Copyright (C) Mattias Päivärinta.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Mattias Päivärinta E<lt>mattias@paivarinta.seE<gt>

=cut
