use v5.41;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use XBench;

for my $case (
    [ [ wrong                => 1 ],                            'UNKNOWN_OPTION' ],
    [ [ seed                 => 1, seed => 2 ],                 'DUPLICATE_OPTION' ],
    [ [ min_samples          => 1 ],                            'INVALID_ARGUMENT' ],
    [ [ min_samples          => 3, max_samples => 2 ],          'INVALID_ARGUMENT' ],
    [ [ warmup               => -1 ],                           'INVALID_ARGUMENT' ],
    [ [ resamples            => 1 ],                            'INVALID_ARGUMENT' ],
    [ [ confidence           => 1 ],                            'INVALID_ARGUMENT' ],
    [ [ max_seconds          => 'NaN' ],                        'INVALID_ARGUMENT' ],
    [ [ target_rel_precision => 0, target_abs_precision => 0 ], 'INVALID_ARGUMENT' ],
    [ [ outlier_method       => 'wrong' ],                      'INVALID_ARGUMENT' ],
    [ ['seed'], 'INVALID_OPTION_LIST' ],
  )
{
    my ( $options, $condition ) = @$case;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval { XBench->new(@$options) };
    ok( ref($@) && $@->has_diagnostic("XBench::$condition"),
        "constructor: $condition" );
    is_deeply( \@warnings, [], 'validation emits no incidental Perl warning' );
}

my $bench = XBench->new;
eval { $bench->run };
ok( ref($@) && $@->has_diagnostic('XBench::NO_CASES'),
    'empty runners fail explicitly' );
is( $bench->state, 'new', 'preflight failure preserves a new runner' );

for my $case (
    [ name => 'missing' ],
    [ name => 'wrong', code    => 1 ],
    [ name => 'both',  code    => sub { }, command => ['program'] ],
    [ name => 'args',  command => [] ],
    [ name => 'args',  command => [ 'program', undef ] ],
    [ name => '',      code    => sub { } ],
    [ name => 'hooks', code    => sub { }, baseline => 1 ],
  )
{
    eval { $bench->add(@$case) };
    ok( ref($@) && $@->has_diagnostic('XBench::INVALID_ARGUMENT'),
        'invalid case rejected' );
}

my $public_line = __LINE__ + 1;
eval { XBench->new( seed => -1 ) };
is( $@->find_diagnostic('XBench::INVALID_ARGUMENT')->location->{line},
    $public_line, 'library conditions retain the public call site' );

my $time = 0;
no warnings 'redefine';
local *XBench::_now = sub { $time };

my $original;
try { die "primary callback failure\n" }
catch ( $value, $exception ) { $original = $exception }

my $cleaned = 0;
my $failed  = XBench->new( warmup => 0, resamples => 20 );
$failed->add(
    name         => 'broken',
    code         => sub { die $original },
    after_sample => sub { ++$cleaned; die "cleanup failure\n" }
);
my $caught;
try { $failed->run }
catch ( $value, $exception ) { $caught = $exception }

is( refaddr($caught), refaddr($original),
    'callback canonical exception retains its identity' );
is( $cleaned,       1,        'cleanup runs after a failing measured callback' );
is( $failed->state, 'failed', 'defer restores the runner state during unwinding' );
is( refaddr( $failed->failure ),
    refaddr($caught), 'runner exposes the canonical failure' );
ok( $caught->has_diagnostic( 'XBench::CASE_CONTEXT', name => 'broken' ),
    'failure gains case context' );
ok( $caught->has_diagnostic( 'XBench::PHASE_CONTEXT', phase => 'calibration' ),
    'failure retains its measurement phase' );
my $rendered = $caught->render('en:legacy');
like(
    $rendered,
    qr/primary callback failure[\s\S]*cleanup failure/,
    'primary and cleanup diagnostics survive in encounter order'
);
eval { $failed->run };
ok(
    ref($@) && $@->has_diagnostic('XBench::STATE'),
    'a failed runner cannot silently rerun'
);

my $before_failed = XBench->new( warmup => 0, resamples => 20 );
$before_failed->add(
    name          => 'setup',
    code          => sub { },
    before_sample => sub { die "setup failure\n" },
    after_sample  => sub { ++$cleaned }
);
eval { $before_failed->run };
is( $cleaned,              1, 'cleanup is not entered when setup did not complete' );
is( $before_failed->state, 'failed', 'setup failure restores state' );

my $partial = XBench->new(
    min_samples     => 2,
    max_samples     => 2,
    warmup          => 0,
    min_sample_time => 0.125,
    max_seconds     => 100,
    resamples       => 20
);
$partial->add( name => 'good', code => sub { $time += 0.125 } );
$partial->add( name => 'bad',  code => sub { die "later failure\n" } );
eval { $partial->run };
is_deeply( [ map { $_->name } @{ $partial->results } ],
    ['good'], 'completed earlier results survive a later failure' );
eval {
    $partial->add( name => 'late', code => sub { } );
};
ok(
    ref($@) && $@->has_diagnostic('XBench::STATE'),
    'a started runner cannot be extended'
);

my $duplicate = XBench->new;
$duplicate->add( name => 'same', code => sub { } );
eval {
    $duplicate->add( name => 'same', code => sub { } );
};
ok( ref($@) && $@->has_diagnostic('XBench::DUPLICATE_NAME'),
    'duplicate names are explicit errors' );

my $weak;
{
    my $one_shot = XBench->new(
        min_samples     => 2,
        max_samples     => 2,
        warmup          => 0,
        min_sample_time => 0.125,
        max_seconds     => 100,
        resamples       => 20
    );
    $weak = $one_shot;
    weaken($weak);
    $one_shot->add(
        name => 'self reference',
        code => sub {
            $time += 0.125;
            $one_shot->state;
        }
    );
    $one_shot->run;
}
ok( !defined($weak),
    'terminal runners release callback captures, including self references' );

SKIP: {
    my $pack = eval { require XPerl::DiagPack::DE; 1 };
    skip 'German diagnostic pack unavailable', 4 unless $pack;

    my $localized = eval q{
        use diagpack 'de';
        eval { XBench->new(seed => -1) };
        $@;
    };
    is(
        $localized->render,
        $localized->render('de:legacy'),
        'argument diagnostics retain the public lexical language'
    );
    isnt(
        $localized->render,
        $localized->render('en:legacy'),
        'captured language affects source-location wording'
    );

    my $contextual = eval q{
        use diagpack 'de';
        my $runner = XBench->new(warmup => 0);
        $runner->add(name => 'translated', code => sub { die "callback failure\n" });
        eval { $runner->run };
        $@;
    };
    my $context = $contextual->find_diagnostic('XBench::CASE_CONTEXT');
    is(
        $context->render,
        $context->render_as_legacy('de'),
        'appended context retains the public lexical language'
    );
    isnt(
        $context->render,
        $context->render_as_legacy('en'),
        'context locations follow the captured language'
    );
}

done_testing;
