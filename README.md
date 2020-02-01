# NAME

**Signal::Queue** - POSIX signals as a queue

# SYNOPSIS

    #!perl
    use Signal::Queue qw( sig_init sig_next );

    sig_init( 'HUP' );
    printf "Hup %s five times!\n", $$;
    printf "%s %s\n", $_, sig_next() for 1 .. 5;
    printf "%s so hapi!\n", $$;

# DESCRIPTION

**Signal::Queue** implements a queue of received POSIX signals.

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

Throughout this module, signals are named as they appear in the `sig_name`
property of the [Config](https://metacpan.org/pod/Config) core module.

# SUBROUTINES

## sig\_init LIST,HASHREF

## sig\_init LIST

Initialize the queue.

    sig_init( 'HUP', 'TERM', { sa_flags => 0 } );

Configures signal handlers for the given signals.

Takes a list of signal names, with an extra last argument that is a hashref of
options.

The option `sa_flags` is an integer of bitflags corresponding to the
`sa_flags` argument of the `sigaction` POSIX system call.
These flags are available as constants prefixed by `SA_` in the [POSIX](https://metacpan.org/pod/POSIX)
module.
The default value is `0`.

Throws an exception if signal information is not available in the [Config](https://metacpan.org/pod/Config)
module,
if already initialized, or
if called with an unrecognized argument.

## sig\_next

Wait for a signal.

    my $sig_name = sig_next();
    print "signal: $sig_name\n";

Blocks the calling thread until there is at least one signal in the queue.
The first signal is then removed from the queue and returned;

Throws an exception if not initialized.

## sig\_ready

Test if the queue is empty.

    if ( sig_ready() ) {
        my $sig_name = sig_next()
        print "signal: $sig_name\n";
    }
    else {
        print "no signal\n";
    }

Throws an exception if not initialized.

## sig\_ignore SIGNAME


Prevents a signal from being extracted.

    sig_ignore( 'TERM' );

Takes a single argument that is a signal name.

After this call, the given signal is never returned by [`sig_next`](#sig_next) again.

Throws an exception if not initialized, or
if the given signal is not among the ones given to [`sig_init`](#sig_init-list).

## sig\_deinit

Deinitialize the queue.

    my @remaining = sig_deinit();

Restores signal handlers for the signals given to [`sig_init`](#sig_init-list).

Any remaining signals are extracted from the queue and returned.

Throws an exception if not initialized.

# EXAMPLES

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

# LICENSE

Copyright (C) Mattias Päivärinta.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Mattias Päivärinta <mattias@paivarinta.se>
