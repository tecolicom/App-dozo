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

# Write a docker stub to $dir/docker, which logs its arguments to $STUB_LOG
# (the stub of t/03_dozo.t, and what -S asks)
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
    ps)      if [[ "$*" == "ps -a -q" ]]; then
                 [[ ! $STUB_PS_FAILS ]] || exit 1
                 for n in $STUB_ALL_IDS; do echo "$n"; done
             elif [[ " $* " == *" --format "* ]]; then
                 for n in $STUB_LABELED; do echo "$n"; done
             else
                 [[ ! $STUB_CONTAINER || -e $STUB_LOG.removed ]] || echo abc123
             fi ;;
    rm)      touch "$STUB_LOG.removed" ;;
    inspect) if [[ "$*" == *'{{.Name}}'* ]]; then
                 [[ ! $STUB_CONTAINERS ]] || cat "$STUB_CONTAINERS"
             elif [[ $2 == --format && $3 == '{{.Image}}' ]]; then echo "$STUB_CONTAINER_IMAGE"
             elif [[ $3 == *dozo.mount* ]]; then echo "$STUB_CONTAINER_MOUNT"
             elif [[ $3 == *dozo.image* ]]; then echo "$STUB_CONTAINER_IMAGE_NAME"
             else echo running; fi ;;
    image)   if [[ $2 == ls ]]; then
                 [[ ! $STUB_DERIVED ]] || cut -f1-3 "$STUB_DERIVED"
             elif [[ $2 == inspect && "$*" == *dozo.base* ]]; then
                 shift 4
                 for t; do
                     awk -F'\t' -v t="$t" '$1 == t { print $4 "\t" $5 }' "$STUB_DERIVED"
                 done
             elif [[ $STUB_IMAGES ]]; then
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

my $dir = Cwd::realpath(tempdir(CLEANUP => 1));
my $log = "$dir/log";
docker_stub($dir);
$ENV{PATH} = "$dir:$ENV{PATH}";
$ENV{STUB_LOG} = $log;
$ENV{HOME} = $dir;
$ENV{XDG_CONFIG_HOME} = "$dir/xdg";
$ENV{STUB_IMAGES} = "$dir/images";
my $home = $dir;
my $work = "$dir/proj";
mkdir $work or die;
system('mkdir', '-p', "$dir/xdg/dozo/features") == 0 or die;
sub put {
    my ($file, $text) = @_;
    open my $fh, '>', $file or die "$file: $!";
    print $fh $text;
}
put("$dir/xdg/dozo/features/hello", "RUN echo hello > /hello\n");
put("$dir/images", "alpine\n");

# the docker calls, and nothing which changes anything
sub calls {
    open my $in, '<', $log or return '';
    my $text = do { local $/; <$in> };
    close $in;
    unlink $log, "$log.removed";
    $text;
}
# dozo ARGS in $work: (stdout, exit status, stderr); checks the calls
sub status {
    my $args = shift;
    my $out = `cd $work && $dozo $args 2>$dir/err`;
    my $st = $? >> 8;
    my $err = do { local (@ARGV, $/) = "$dir/err"; <> } // '';
    my $l = calls();
    unlike($l, qr/^(pull|build|rm|run|start|unpause|exec|attach)\b/m,
           "$args: nothing is changed");
    ($out, $st, $err, $l);
}
sub rc { put("$home/.dozorc", shift) }

subtest 'here' => sub {
    unlink "$home/.dozorc";
    my ($out, $st, $err) = status('-S -I alpine');
    is($st, 0, '-I: exit status');
    like($out, qr/^here: \Q$work\E$/m, 'the directory');
    like($out, qr/^  image +alpine \(command line\)$/m, 'image from the command line');
    like($out, qr/^  container +alpine\.proj, (none|create)/m, 'no container: created');

    rc("-D\n");
    ($out, $st) = status('-S');
    like($out, qr/image +tecolicom\/xlate \(\Q$home\E\/\.dozorc\)/, 'image from .dozorc');

    {
        local $ENV{STUB_LABELED} = 'alpine.proj';
        local $ENV{STUB_CONTAINER} = 1;
        local $ENV{STUB_CONTAINER_IMAGE_NAME} = 'alpine:3.18';
        ($out, $st) = status('-S');
        is($st, 0, 'by label: exit status');
        like($out, qr/container +alpine\.proj, running \(found by label\)/, 'found by label');
        like($out, qr/image +alpine:3\.18 \(label of alpine\.proj\)/, 'image of the label');

        ($out, $st) = status('-KL -S');
        is($st, 0, '-KL: exit status');
        like($out, qr/would remove alpine\.proj/, '-KL: would remove');
        like($out, qr/then create from alpine:3\.18/, '-KL: then create');
    }
    unlink "$home/.dozorc";
    {
        local $ENV{STUB_LABELED} = 'alpine.proj debian.proj';
        local $ENV{STUB_CONTAINER} = 1;
        ($out, $st) = status('-S');
        is($st, 0, 'several: exit status');
        like($out, qr/several containers.*alpine\.proj.*debian\.proj/, 'several: listed');
    }

    ($out, $st) = status('-S');
    is($st, 0, 'no image: exit status');
    like($out, qr/no live container for .*-I/, 'no image: as the error');

    ($out, $st) = status('-A -S -I alpine');
    like($out, qr/-A.*would pull alpine/, '-A: would pull');

    ($out, $st) = status('--with hello -S -I alpine');
    is($st, 0, '--with: exit status');
    like($out, qr/--with +hello: .*not built yet/, '--with: not built yet');
    ($out, $st) = status('--with nosuch -S -I alpine');
    is($st, 0, 'unknown feature: exit status');
    like($out, qr/nosuch.*not found/, 'unknown feature: told');
    ($out, $st) = status('--with hello,nosuch -S -I debian');
    like($out, qr/nosuch.*not found/, 'unknown feature, base image not here: told');

    {
        local $ENV{STUB_CONTAINER} = 1;
        local $ENV{STUB_CONTAINER_MOUNT} = '/other/proj';
        ($out, $st) = status('-S -I alpine');
        is($st, 0, 'other directory: exit status');
        like($out, qr/^  note +.*\/other\/proj/m, 'other directory: note');
    }

    ($out, $st, $err) = status('-S -I alpine echo hi');
    isnt($st, 0, 'a command: error');
    like($err, qr/--status takes no command/, 'a command: told');

    {
        local $ENV{STUB_PS_FAILS} = 1;
        ($out, $st) = status('-S -I alpine');
        isnt($st, 0, 'docker cannot be asked: error');
    }
};

subtest '.dozorc stray word' => sub {
    put("$home/.dozorc", "-I alpine foo\n");
    put("$work/.dozorc", "-E X\n");
    `cd $work && $dozo -B bar 2>/dev/null`;
    like(calls(), qr/^run .* alpine foo -E X -B bar$/m, 'the rest is the command');
    unlink "$home/.dozorc", "$work/.dozorc";
};

done_testing;
