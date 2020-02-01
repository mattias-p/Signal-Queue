requires 'perl', '5.008001';
requires 'Carp', '>= 1.01';
requires 'Config';
requires 'POSIX', '>= 1.06';

on 'test' => sub {
    requires 'Test::More',      '0.98';
    requires 'Test::Exception', '0.43';
};

