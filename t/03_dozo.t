use v5.14;
use warnings;
use utf8;

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd ();

# Skip tests on platforms without bash or with old bash
BEGIN {
    my $bash_check = `bash --version 2>&1`;
    if ($? != 0) {
        plan skip_all => 'bash is not available on this system';
    }
    if ($bash_check =~ /version (\d+)\.(\d+)/) {
        my ($major, $minor) = ($1, $2);
        if ($major < 4 || ($major == 4 && $minor < 3)) {
            plan skip_all => "bash 4.3+ required (found $major.$minor)";
        }
    }
}

# Skip if getoptlong.sh is not available
BEGIN {
    my $check = `command -v getoptlong.sh 2>/dev/null`;
    if ($? != 0) {
        plan skip_all => 'getoptlong.sh is not available in PATH';
    }
}

my $dozo = File::Spec->rel2abs('script/dozo');

# Use empty temp dir to avoid reading any .dozorc (HOME, git top, cwd)
my $empty_home = tempdir(CLEANUP => 1);
$ENV{HOME} = $empty_home;
chdir $empty_home or die "Cannot chdir to $empty_home: $!";

# Check if dozo exists
ok(-x $dozo, 'dozo is executable');

# Test: help option
subtest 'help option' => sub {
    my $out = `$dozo --help 2>&1`;
    like($out, qr/dozo.*Docker.*Zero Overhead/i, '--help shows description');
    like($out, qr/--image/, '--help shows --image option');
    like($out, qr/--live/, '--help shows --live option');
    like($out, qr/--kill/, '--help shows --kill option');
};

# Test: missing image error
subtest 'missing image error' => sub {
    my $out = `$dozo echo hello 2>&1`;
    my $status = $? >> 8;
    isnt($status, 0, 'exits with error when no image specified');
    like($out, qr/image.*must be specified/i, 'error message mentions image');
};

# Test: option parsing (valid options should reach "image must be specified" error)
subtest 'option parsing' => sub {
    my $out = `$dozo -W -B -R 2>&1`;
    unlike($out, qr/no such option/i, 'options -W -B -R are recognized');
    like($out, qr/image.*must be specified/i, 'reaches image check (options parsed successfully)');
};

# Test: combined options like -KL
subtest 'combined options' => sub {
    my $out = `$dozo --help 2>&1`;
    like($out, qr/--kill/, '-K option documented');
    like($out, qr/--live/, '-L option documented');
};

# Test: .dozorc parsing with quoted arguments
subtest '.dozorc parsing' => sub {
    my $test_dir = tempdir(CLEANUP => 1);
    my $rc_file = "$test_dir/.dozorc";

    local $ENV{HOME} = $test_dir;
    chdir $test_dir or die "Cannot chdir to $test_dir: $!";

    # Test simple option: -I should set the image
    open my $fh, '>', $rc_file or die "Cannot create $rc_file: $!";
    print $fh "-I testimage:latest\n";
    close $fh;

    # With -I set in .dozorc, should not get "image must be specified" error
    my $out = `$dozo -n echo test 2>&1`;
    unlike($out, qr/image.*must be specified/i, '.dozorc -I option is parsed');

    # Test quoted argument with spaces
    open $fh, '>', $rc_file or die "Cannot create $rc_file: $!";
    print $fh qq{-E "TEST_VAR=hello world"\n};
    close $fh;

    # Should still get "image must be specified" (no -I), but no parse error
    $out = `$dozo echo test 2>&1`;
    like($out, qr/image.*must be specified/i, '.dozorc with quoted args is parsed without error');
    unlike($out, qr/xargs|error|unterminated/i, 'no parsing error for quoted args');
};

# Test: -V option without colon (same path mount)
subtest '-V option without colon' => sub {
    my $test_dir = tempdir(CLEANUP => 1);
    my $rc_file = "$test_dir/.dozorc";

    local $ENV{HOME} = $test_dir;
    chdir $test_dir or die "Cannot chdir to $test_dir: $!";

    # Test single path without colon in .dozorc
    open my $fh, '>', $rc_file or die "Cannot create $rc_file: $!";
    print $fh "-I alpine\n";
    print $fh "-V /var/run/docker.sock\n";
    close $fh;

    # Should parse without error (use -n to avoid running docker)
    my $out = `$dozo -n echo test 2>&1`;
    unlike($out, qr/no such option|invalid.*option|getoptlong/i, '-V without colon is parsed without error');

    # Test multiple paths (comma-separated)
    open $fh, '>', $rc_file or die "Cannot create $rc_file: $!";
    print $fh "-I alpine\n";
    print $fh "-V /tmp,/var/tmp\n";
    close $fh;

    $out = `$dozo -n echo test 2>&1`;
    unlike($out, qr/no such option|invalid.*option|getoptlong/i, '-V with comma-separated paths is parsed without error');

    # Test path with colon (explicit mount) using existing paths
    open $fh, '>', $rc_file or die "Cannot create $rc_file: $!";
    print $fh "-I alpine\n";
    print $fh "-V /tmp:/container/tmp\n";
    close $fh;

    $out = `$dozo -n echo test 2>&1`;
    unlike($out, qr/no such option|invalid.*option|getoptlong/i, '-V with explicit colon mount has no parsing error');
};

# Test: -B passes piped input but does not wait for a terminal
subtest '-B with piped input' => sub {
    my $out = `echo x | $dozo -B -n -I alpine true 2>&1`;
    like($out, qr/--interactive/, '-B with a pipe keeps --interactive');
    unlike($out, qr/--tty/, '-B with a pipe gives no --tty');
    $out = `$dozo -n -I alpine true </dev/null 2>&1`;
    like($out, qr/--interactive/, 'without -B --interactive is given');
};

# Test: --bundle prints a single file that runs without getoptlong.sh
subtest '--bundle' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $bundled = "$dir/dozo";
    system("$dozo -q --bundle > $bundled") == 0 or die "--bundle failed";
    chmod 0755, $bundled;
    open my $fh, '<', $bundled or die;
    my $text = do { local $/; <$fh> };
    close $fh;
    like($text, qr/\A#!.*\n# getoptlong\.sh embedded by dozo --bundle\n(?s:.*)^gol_parse \(\)(?s:.*)^# end of getoptlong\.sh\n/m,
         'getoptlong.sh is inserted after the first line');
    my ($orig) = do { local(@ARGV, $/) = ($dozo); <> };
    my $body = $orig =~ s/\A.*\n//r;
    like($text, qr/\Q$body\E\z/, 'the rest of dozo follows unchanged');

    # a PATH with bash but without getoptlong.sh
    my $bin = "$dir/bin";
    mkdir $bin;
    my ($bash) = grep { -x } map { "$_/bash" } split /:/, $ENV{PATH};
    symlink $bash, "$bin/bash" or die "bash not found in PATH";
    local $ENV{PATH} = "$bin:/usr/bin:/bin";
    my $out = `$bundled -n -I alpine echo test 2>&1`;
    like($out, qr/docker run .* alpine echo test/, 'bundled dozo runs without getoptlong.sh');
    $out = `$bundled --no-such-option 2>&1`;
    like($out, qr/no such option/, 'bundled dozo parses options');
    is(`$bundled -q --bundle`, $text, 'bundling a bundled dozo gives the same file');

    # no messages on stderr, even with a .dozorc to report
    my $home = "$dir/home";
    mkdir $home;
    open my $rc, '>', "$home/.dozorc" or die;
    print $rc "-I alpine\n";
    close $rc;
    local $ENV{HOME} = $home;
    is(`$bundled --bundle 2>&1 >/dev/null`, '', '--bundle prints nothing on stderr');
};

# Write a docker stub to $dir/docker, which logs its arguments to $STUB_LOG
sub docker_stub {
    my $dir = shift;
    open my $fh, '>', "$dir/docker" or die;
    print $fh <<'STUB';
#!/bin/bash
echo "$*" >> "$STUB_LOG"
case $1 in
    pull)    echo pulled
             [[ ! $STUB_PULL_ADDS ]] || echo "$2" >> "$STUB_IMAGES"
             [[ ! $STUB_PULL_FAILS ]] ;;
    ps)      [[ ! $STUB_CONTAINER ]] || echo abc123 ;;
    inspect) if [[ $2 == --format && $3 == '{{.Image}}' ]]; then echo "$STUB_CONTAINER_IMAGE"
             else echo running; fi ;;
    image)   if [[ $STUB_IMAGES ]]; then
                 grep -qxF -- "${@: -1}" "$STUB_IMAGES" 2>/dev/null || exit 1
                 case $4 in
                     '{{.Id}}')                echo "sha256:${@: -1}" ;;
                     '{{.Config.User}}')       echo "$STUB_USER" ;;
                     '{{json .Config.Entrypoint}}') echo "${STUB_ENTRYPOINT:-null}" ;;
                 esac
             else
                 echo "${STUB_ENTRYPOINT:-null}"
             fi ;;
    build)   n=1
             while [[ -e $STUB_LOG.dockerfile.$n ]]; do n=$((n+1)); done
             cat > "$STUB_LOG.dockerfile.$n"
             [[ ! $STUB_BUILD_FAILS ]] || exit 1
             while (( $# )); do
                 [[ $1 == -t ]] && echo "$2" >> "$STUB_IMAGES"
                 shift
             done ;;
    run)     if [[ " $* " == *" --entrypoint sh "* ]]; then
                 echo "${STUB_HOME:-/root}"; exit 0
             fi
             [[ ! $STUB_RUN_FAILS ]] || exit 1; echo ran ;;
    exec)    echo execed; exit ${STUB_EXEC_STATUS:-0} ;;
esac
STUB
    close $fh;
    chmod 0755, "$dir/docker" or die;
}

subtest '-A' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $log = "$dir/log";
    docker_stub($dir);
    local $ENV{PATH} = "$dir:$ENV{PATH}";
    local $ENV{STUB_LOG} = $log;
    my $calls = sub {
        open my $in, '<', $log or return '';
        my $text = do { local $/; <$in> };
        close $in;
        unlink $log;
        $text;
    };

    my $out = `$dozo -I alpine true 2>/dev/null`;
    unlike($calls->(), qr/^pull/m, 'no pull without -A');

    $out = `$dozo -A -I alpine true 2>/dev/null`;
    is($?, 0, 'exit status');
    is($out, "ran\n", 'the output of pull is not on stdout');
    like($calls->(), qr/^pull alpine\nrun .* alpine true$/m, 'pull, then run');

    $out = `$dozo --auto-pull -q -I alpine true 2>&1`;
    is($out, "ran\n", '-q shows nothing of pull');
    like($calls->(), qr/^pull --quiet alpine\n/m, '--auto-pull -q');

    {
        local $ENV{STUB_PULL_FAILS} = 1;
        $out = `$dozo -A -I alpine true 2>&1`;
        like($out, qr/cannot pull alpine/, 'failed pull is reported');
        like($out, qr/^ran$/m, 'and the command still runs');
        is($?, 0, 'with its own exit status');
        $calls->();
    }

    {
        local $ENV{STUB_CONTAINER} = 1;
        $out = `$dozo -A -L -I alpine true 2>&1`;
        like($out, qr/-K/, 'existing live container: tells about -K');
        like($out, qr/^execed$/m, 'and uses the container');
        unlike($calls->(), qr/^pull/m, 'no pull for an existing container');
    }

    $out = `$dozo -A -L -I alpine true 2>/dev/null`;
    like($calls->(), qr/^pull alpine\n/m, 'pull for a new live container');

    {
        # the subtests above leave a .dozorc with -I in the home directory
        local $ENV{HOME} = $dir;
        $out = `cd $dir && $dozo -A true 2>&1`;
        like($out, qr/image.*must be specified/i, 'no image: error');
        unlike($calls->(), qr/^pull/m, 'no pull without an image');
    }
};

subtest '-L creates a container, then execs the command' => sub {
    # realpath: on macOS, git shows /private/var for the /var tempdir
    my $dir = Cwd::realpath(tempdir(CLEANUP => 1));
    my $log = "$dir/log";
    docker_stub($dir);
    local $ENV{PATH} = "$dir:$ENV{PATH}";
    local $ENV{STUB_LOG} = $log;
    my $calls = sub {
        open my $in, '<', $log or return '';
        my $text = do { local $/; <$in> };
        close $in;
        unlink $log;
        $text;
    };

    my $out = `$dozo -L -I alpine echo hi 2>/dev/null`;
    is($?, 0, 'exit status');
    is($out, "execed\n", 'only the output of the command is on stdout');
    my $log1 = $calls->();
    like($log1, qr/^run .*--detach\b.* alpine$/m, 'run detached without the command');
    like($log1, qr/^run .*--interactive\b.*--tty\b/m, 'with --interactive --tty');
    like($log1, qr/^exec .* alpine\.\S+ echo hi$/m, 'then exec the command');

    {
        local $ENV{STUB_EXEC_STATUS} = 3;
        `$dozo -L -I alpine false 2>/dev/null`;
        is($? >> 8, 3, 'exit status of the command');
        $calls->();
    }

    {
        local $ENV{STUB_RUN_FAILS} = 1;
        `$dozo -L -I alpine echo hi 2>/dev/null`;
        isnt($?, 0, 'failed run: non-zero exit');
        unlike($calls->(), qr/^exec/m, 'failed run: no exec');
    }

    $out = `$dozo -L -I alpine 2>/dev/null`;
    my $log2 = $calls->();
    like($log2, qr/^run .* alpine$/m, 'no command: run as before');
    unlike($log2, qr/--detach/, 'no command: not detached');
    unlike($log2, qr/^exec/m, 'no command: no exec');

    {
        # the command is given to the entrypoint, as before
        local $ENV{STUB_ENTRYPOINT} = '["/usr/bin/hugo"]';
        $out = `$dozo -L -I alpine version 2>/dev/null`;
        my $log3 = $calls->();
        like($log3, qr/^run .* alpine version$/m, 'entrypoint: run with the command');
        unlike($log3, qr/--detach/, 'entrypoint: not detached');
        unlike($log3, qr/^exec/m, 'entrypoint: no exec');
    }

    $out = `$dozo -n -L -I alpine echo hi 2>/dev/null`;
    like($out, qr/^docker run .*--detach\b.* alpine$/m, 'dryrun shows docker run');
    like($out, qr/^docker exec .* echo hi$/m, 'dryrun shows docker exec');
    $calls->();

    SKIP: {
        skip 'git is not available', 1 if system('git --version >/dev/null 2>&1') != 0;
        my $sub = "$dir/repo/sub";
        system("mkdir -p $sub && cd $dir/repo && git init -q") == 0 or die;
        $out = `cd $sub && $dozo -L -I alpine pwd 2>/dev/null`;
        like($calls->(), qr{^exec .*--workdir /work/sub\b.* pwd$}m,
             'from a subdirectory: exec in it');
    }
};

subtest '--with' => sub {
    my $dir = Cwd::realpath(tempdir(CLEANUP => 1));
    my $log = "$dir/log";
    docker_stub($dir);
    local $ENV{PATH} = "$dir:$ENV{PATH}";
    local $ENV{STUB_LOG} = $log;
    local $ENV{HOME} = $dir;
    local $ENV{XDG_CONFIG_HOME} = "$dir/config";
    local $ENV{STUB_IMAGES} = "$dir/images";
    my $calls = sub {
        open my $in, '<', $log or return '';
        my $text = do { local $/; <$in> };
        close $in;
        unlink $log;
        $text;
    };
    my $spit = sub {
        my ($file, $text) = @_;
        (my $d = $file) =~ s{/[^/]*$}{};
        system('mkdir', '-p', $d);
        open my $o, '>', $file or die "$file: $!";
        print $o $text;
        close $o;
    };
    my $dockerfile = sub {
        open my $in, '<', "$log.dockerfile.$_[0]" or return '';
        local $/;
        scalar <$in>;
    };
    my $images = sub { $spit->("$dir/images", join '', map "$_\n", @_) };

    my $fd = "$dir/config/dozo/features";
    $spit->("$fd/locale", "ENV LANG=C.UTF-8\n");
    $spit->("$fd/home/Dockerfile", "COPY . \$DOZO_HOME/\n");
    $spit->("$fd/home/.inputrc", "x\n");
    $images->('alpine');

    my $out = `$dozo -I alpine --with locale,home echo hi 2>/dev/null`;
    is($?, 0, 'exit status');
    is($out, "ran\n", 'only the output of the command is on stdout');
    my $l = $calls->();
    my @build = $l =~ /^build .*$/mg;
    is(scalar @build, 2, 'two stages are built');
    like($build[0], qr/-t dozo\/alpine:locale-\d+ -$/, 'file feature: no context');
    like($build[1], qr/-t dozo\/alpine:home-\d+ -f - \Q$fd\E\/home$/, 'directory feature: context');
    like($l, qr/^run .* dozo\/alpine:home-\d+ echo hi$/m, 'run the last stage');
    like($dockerfile->(1), qr/\AFROM alpine\nARG DOZO_USER=root\nARG DOZO_HOME=\/root\nENV LANG=C.UTF-8\n\z/, 'generated Dockerfile');

    like($dockerfile->(2), qr/\AFROM dozo\/alpine:locale-\d+\n/, 'next stage is built FROM the previous tag');

    `$dozo -I alpine --with locale,home echo hi 2>/dev/null`;
    unlike($calls->(), qr/^build/m, 'second time: nothing is built');

    `$dozo -I alpine --with locale,home echo hi 2>/dev/null`;
    my @inspect = $calls->() =~ /^image inspect --format \{\{\.Id\}\} /mg;
    is(scalar @inspect, 3, 'all cached, 2 features: one inspect for the base and one per stage');

    `$dozo -I alpine --with locale --with home echo hi 2>/dev/null`;
    unlike($calls->(), qr/^build/m, 'repeated --with is the same as a comma list');

    $spit->("$fd/home/.inputrc", "changed\n");
    `$dozo -I alpine --with locale,home echo hi 2>/dev/null`;
    @build = $calls->() =~ /^build .*$/mg;
    is(scalar @build, 1, 'changing a feature rebuilds from that stage');
    like($build[0], qr/-t dozo\/alpine:home-/, 'only that stage');

    # files made by Finder and editors do not change the tag
    $spit->("$fd/home/$_", "junk\n")
        for '.DS_Store', '.inputrc~', '.inputrc.swp', '.inputrc.swo', '#.inputrc#', '.#.inputrc';
    `$dozo -I alpine --with locale,home echo hi 2>/dev/null`;
    unlike($calls->(), qr/^build/m, 'Finder and editor files are ignored');

    {
        local $ENV{STUB_USER} = '1000:1000';
        $spit->("$fd/other", "RUN true\n");
        `$dozo -I alpine --with other echo hi 2>/dev/null`;
        $calls->();
        my $df = $dockerfile->(4);
        like($df, qr/^ARG DOZO_USER=1000:1000$/m, 'USER is restored as given: ARG');
        like($df, qr/\nUSER 1000:1000\n\z/, 'USER is restored as given: last line');
    }

    `$dozo -I alpine -H --with locale echo hi 2>/dev/null`;
    is($?, 0, '-H does not move the feature directory');
    $calls->();

    {
        $images->();
        my $err = `$dozo -I alpine --with locale echo hi 2>&1 >/dev/null`;
        isnt($?, 0, 'missing base image that cannot be pulled');
        like($err, qr/cannot find image/, 'with a message');
        unlike($calls->(), qr/^run /m, 'and nothing is run');

        {
            local $ENV{STUB_PULL_FAILS} = 1;
            $images->();
            $err = `$dozo -A -I alpine --with locale echo hi 2>&1 >/dev/null`;
            isnt($?, 0, '-A: missing base image whose pull fails');
            unlike($err, qr/using the local image/, '-A: no "using the local image"');
            like($err, qr/cannot find image/, '-A: with a message');
            my @pull = $calls->() =~ /^pull /mg;
            is(scalar @pull, 1, '-A: the failing pull is tried once');
            $images->();
            $err = `$dozo -I alpine --with locale echo hi 2>&1 >/dev/null`;
            unlike($err, qr/using the local image/, 'no "using the local image" without -A either');
            like($err, qr/cannot find image/, 'with a message');
            $calls->();
        }

        {
            local $ENV{STUB_PULL_ADDS} = 1;
            $images->();
            `$dozo -A -I alpine --with locale echo hi 2>/dev/null`;
            my @pull = $calls->() =~ /^pull /mg;
            is(scalar @pull, 1, '-A --with: the missing base is pulled once');
        }

        $images->();
        local $ENV{STUB_PULL_ADDS} = 1;
        `$dozo -I alpine --with locale echo hi 2>/dev/null`;
        is($?, 0, 'missing base image is pulled');
        like($calls->(), qr/^pull alpine\n(?:.*\n)*?build .*\n(?:.*\n)*?run .* echo hi$/m,
             'pull, then build and run');
    }

    {
        my $err = `$dozo -I alpine --with nosuch echo hi 2>&1 >/dev/null`;
        isnt($?, 0, 'unknown feature');
        like($err, qr/\Q$fd\E/, 'tells the feature directory');
        $calls->();
        for my $n ('../x', 'a/b') {
            `$dozo -I alpine --with $n echo hi 2>/dev/null`;
            isnt($?, 0, "feature name with a slash: $n");
            unlike($calls->(), qr/^build/m, 'nothing is built');
        }
    }

    {
        local $ENV{STUB_BUILD_FAILS} = 1;
        $spit->("$fd/new", "RUN true\n");
        `$dozo -I alpine --with new echo hi 2>/dev/null`;
        isnt($?, 0, 'build failure');
        unlike($calls->(), qr/^run .* echo hi$/m, 'the command is not run');
    }

    `$dozo -I alpine echo hi 2>/dev/null`;
    unlike($calls->(), qr/^image inspect --format \{\{\.Id/m, 'no --with: no image inspect');

    # -L, no container: created from the derived image, named after the original
    $images->('alpine');
    $out = `$dozo -L -I alpine --with locale echo hi 2>/dev/null`;
    my $log = $calls->();
    like($log, qr/^run .*--name alpine\.\S+ .*dozo\/alpine:locale-\d+$/m, '-L: named after the original image');
    like($log, qr/^run .*--hostname alpine\b/m, '-L: hostname from the original image');

    # -L, existing container on the same image: no notice
    open my $im, '<', "$dir/images" or die;
    my ($locale) = grep /^dozo\/alpine:locale-/, map { chomp; $_ } <$im>;
    close $im;
    {
        local $ENV{STUB_CONTAINER} = 1;
        local $ENV{STUB_CONTAINER_IMAGE} = "sha256:$locale";
        $out = `$dozo -L -I alpine --with locale echo hi 2>&1`;
        unlike($out, qr/-K/, 'same image: no notice');
        $calls->();

        # -L, existing container on another image: notice, and nothing is built
        $out = `$dozo -L -I alpine --with locale,home echo hi 2>&1`;
        like($out, qr/--with does not change existing container \S+, use -K to recreate it/, 'different image: notice');
        unlike($calls->(), qr/^build/m, 'existing container: nothing is built');
    }

    # dryrun: shows build and run, builds nothing, runs no probe
    $spit->("$fd/newone", "RUN true\n");
    $out = `$dozo -n -I alpine --with newone echo hi 2>/dev/null`;
    is($?, 0, 'dryrun: exit status');
    like($out, qr/^docker build .* -t dozo\/alpine:newone-\d+ /m, 'dryrun shows docker build');
    like($out, qr/^docker run .* dozo\/alpine:newone-\d+ echo hi$/m, 'dryrun shows docker run');
    $log = $calls->();
    unlike($log, qr/^build/m, 'dryrun builds nothing');
    unlike($log, qr/^run /m, 'dryrun runs nothing');

    # dryrun, two new stages and a missing base: pull, two builds, run
    $images->();
    $spit->("$fd/newtwo", "RUN true\n");
    $out = `$dozo -n -I alpine --with newone,newtwo echo hi 2>&1`;
    is($?, 0, 'dryrun: missing base, exit status');
    like(join("\n", grep { /^docker / && !/^docker run image=/ } split /\n/, $out) . "\n",
         qr/\Adocker pull alpine\ndocker build .*\ndocker build .*\ndocker run .* echo hi\n\z/,
         'dryrun: pull, build, build, run');
    unlike($calls->(), qr/^(?:pull|build|run) /m, 'dryrun: nothing really done');

    # -A -n without --with: the pull line stays on stderr
    $out = `$dozo -n -A -I alpine true 2>/dev/null`;
    unlike($out, qr/docker pull/, '-A -n: no docker pull on stdout');
    $calls->();
};

done_testing;
