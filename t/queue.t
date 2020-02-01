use strict;
use Test::More 0.98;
use Test::Exception;

use POSIX;

use Signal::Queue qw( sig_init sig_next sig_ignore sig_ready sig_deinit );

subtest 'double initialization' => sub {
    lives_ok { sig_init( 'USR1', 'ALRM', 'HUP' ) };

    throws_ok { sig_init( 'USR1', 'ALRM', 'HUP' ) } qr/initialized/;

    sig_deinit();
};

subtest 'populating and consuming the queue' => sub {
    sig_init( 'USR1' );

    ok !sig_ready(), 'queue starts out empty';
    kill USR1 => $$ or BAIL_OUT('failed to send signal');
    ok sig_ready(), 'queue is populated by signals';
    sig_next();
    ok !sig_ready(), 'queue is consumed by sig_next()';

    sig_deinit();
};

subtest 'sig_next() returns caught signals' => sub {
    sig_init( 'USR1' );

    kill USR1 => $$ or BAIL_OUT('failed to send signal');
    is sig_next(), 'USR1';

    sig_deinit();
};

subtest 'sig_next() returns signals in the correct order' => sub {
    sig_init( 'ALRM', 'USR1' );

    kill ALRM => $$ or BAIL_OUT('failed to send signal');
    kill USR1 => $$ or BAIL_OUT('failed to send signal');

    is sig_next(), 'ALRM';
    is sig_next(), 'USR1';

    kill USR1 => $$ or BAIL_OUT('failed to send signal');
    kill ALRM => $$ or BAIL_OUT('failed to send signal');

    is sig_next(), 'USR1';
    is sig_next(), 'ALRM';

    sig_deinit();
};

subtest 'sig_next() coalesces identical unhandled signals' => sub {
    sig_init( 'ALRM', 'USR1' );

    kill USR1 => $$ or BAIL_OUT('failed to send signal');
    kill ALRM => $$ or BAIL_OUT('failed to send signal');
    kill USR1 => $$ or BAIL_OUT('failed to send signal');

    is sig_next(), 'USR1';
    is sig_next(), 'ALRM';
    ok !sig_ready();

    sig_deinit();
};

subtest 'sig_ignore() evicts existing entries from queue ...' => sub {
    sig_init( 'ALRM', 'HUP', 'USR1' );

    kill USR1 => $$ or BAIL_OUT('failed to send signal');
    kill HUP  => $$ or BAIL_OUT('failed to send signal');
    kill ALRM => $$ or BAIL_OUT('failed to send signal');

    sig_ignore('HUP');

    is sig_next(), 'USR1';
    is sig_next(), 'ALRM';
    ok !sig_ready();

    subtest "... and it doesn't let new ones in" => sub {
        kill USR1 => $$ or BAIL_OUT('failed to send signal');
        kill HUP  => $$ or BAIL_OUT('failed to send signal');
        kill ALRM => $$ or BAIL_OUT('failed to send signal');

        is sig_next(), 'USR1';
        is sig_next(), 'ALRM';
        ok !sig_ready();
    };

    sig_deinit();
};

subtest 'SLOW: sig_next() blocks while queue is empty' => sub {
    sig_init( 'ALRM' );

    alarm(2);
    is sig_next(), 'ALRM';

    sig_deinit();
};

subtest 'SLOW: sig_wait() returns immediately when queue is non-empty' => sub {
    sig_init( 'ALRM', 'USR1' );

    my $test_pid = $$;
    kill USR1 => $test_pid;    # put something in the queue

    my $done;
    my $done_sub = sub { $done = 1 };
    my $die_sub = sub { die "WAT?!\n" };

    $SIG{ALRM} = $die_sub;

    alarm(2);

    is sig_next(), 'USR1';
    $SIG{ALRM} = $done_sub;

    POSIX::pause();
    is $done, 1;    # sanity check

    sig_deinit();
};

done_testing;
