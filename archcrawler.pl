#!/usr/bin/env perl

use strict;
use warnings;

use Carp;
use Getopt::Long;
use POSIX qw/strftime/;
use Fcntl ':seek';
use LWP::UserAgent;
use File::Spec;
use Cwd 'realpath';
use base qw/File::Path File::Copy/;

die "error: this program need to be run as root.\n"
    unless $> == 0;

our @EXPORT_OK = qw/all custom upgrade pacnew mount umount hostname/;
our $profile;
our $custom;
our $list;
our $device;
our $partition;
our $target = 'target';
our $verbose;
our $debug;
our @pacman = ('pacman');
our $arch = `uname -m`;
chop $arch;
our $tmp = "/tmp";
our $sshkey;
our $hostname;

our $ua = LWP::UserAgent->new;

sub help {
    my $included_paths = join("\n", map {"    $_"} @INC);
    print <<EOF;
ArchCrawler - Arch Deployment script

Usage: $0
    <--profile=PROFILE|-p PROFILE> [<--list|-l>]
    [<--target TARGET|-t TARGET>] [<--hostname HOSTNAME>]
    [<--device DEVICE|--dev DEVICE|-d DEVICE>] [<--partition|--part PARTITION>]
    [<--ssh-key PUBLIC_KEY>] [<--custom CUSTOM|-c CUSTOM>]
    [<--verbose|-v>] [<--help|-h>]

Arguments:

    PROFILE     must be found in profile.d directory in included paths
    TARGET      target directory (mount point of the root filesystem)
                default: ./target
    DEVICE      target device to install the system
                example: /dev/sdb
    PARTITION   target partition to install the system
                example: 1 (which means /dev/sdb1 if DEVICE is /dev/sdb)
    HOSTNAME    hostname
    PUBLIC_KEY  public key file to use for ssh authorized keys
    CUSTOM      must be found in custom.d dir in included paths

Parameters:

    --list, -l
        list all existing profiles
    --verbose, -v
        verbose mode
    --debug
        activate debug mode
    --help, -h
        this help

Included paths:
$included_paths

EOF
    exit 0
}

sub load_script {
    my($dir,$script) = @_;
    return unless $script;
    my $file;
    foreach( map {"$_/$dir/$script"} @INC ) {
        next unless -f $_;
        $file = $_;
    }
    die "error: can not find script $dir/$script in ".join(':', @INC)."\n"
        unless $file;
    local $/;
    open SCRIPT,$file or die $!;
    my $code = <SCRIPT>;
    close SCRIPT;
    eval $code;
    die "fatal: can not load `$file': ", $@ if $@;
    undef $@;
}

sub human_size {
    $_ = shift;
    # TiB: 1024 GiB
    return sprintf("%.2f TiB", $_ / 1099511627776) if $_ > 1099511627776;
    # GiB: 1024 MiB
    return sprintf("%.2f GiB", $_ / 1073741824) if $_ > 1073741824;
    # MiB: 1024 KiB
    return sprintf("%.2f MiB", $_ / 1048576) if $_ > 1048576;
    # KiB: 1024 B
    return sprintf("%.2f KiB", $_ / 1024) if $_ > 1024;
    return "$_ byte" . ($_ == 1 ? "" : "s");
}

sub download {
    my($url,$filename) = @_;
    $filename = $& if not $filename and $url =~ m/[^\/]+$/;
    my $target_is_set;
    my $target = 0;
    my $progress = 0;
    my($t1,$t2) = (0, 0);
    local $| = 1;
    if( -f $filename ) {
        print "info: $filename already exists, skipped\n";
        return $filename;
    }
    print "getting $url...\n";
    open OUTPUT, '>', $filename
        or die "error: cannot open file `$filename': $!\n";
    my $res = $ua->get($url, ':content_cb' => sub {
            my ($chunk,$response,$protocol) = @_;
            unless( $target_is_set ) {
                if( my $cl = $response->content_length) {
                    $target = $cl;
                    $target_is_set = 1;
                } else {
                    $target = $progress + 2 * length $chunk;
                }
            }

            $progress += length $chunk;
            print OUTPUT $chunk;

            ($t1, $t2) = ($t2, strftime('%s', gmtime));
            if( $t2 - $t1 > 0 ) {
                my $percent = int($progress/$target*100);
                my $bar = int($percent / 2);
                print "[".('#' x $bar).(' ' x (50-$bar))."]   ".
                    "$percent%   ".human_size($progress).
                    "/".human_size($target)."...  \r";
            }
        });
    die "error: can not download: ".$res->status_line."\n"
        unless $res->is_success;
    close OUTPUT;
    print "\n";
    return $filename;
}

sub rmtree {
    # TODO: deny access to root filesystem
    for( map {glob $_} @_ ) {
        File::Path::rmtree $_, {verbose => $verbose}
            or die "error: rmtree $_: $!\n";
    }
}

sub mkpath {
    # TODO: deny access to root filesystem
    File::Path::mkpath @_, {verbose => $verbose};
    die "error: mkpath @_: directory does not exist!\n" if grep {not -e} @_;
}

sub safe_system {
    print join(' ', map {
            if( m/\s/ ) {
                s/\\/\\\\/g;
                s/"/\\"/g;
                "\"$_\"";
            } else { $_ }
        } @_)."\n";
    system(@_);
    if( $? == -1 ) {
        confess "failed to execute!";
    } elsif ($? & 127) {
        confess sprintf "child died with signal %d, %s coredump",
            ($? & 127),  ($? & 128) ? 'with' : 'without';
    } elsif( $? >> 8 != 0 ) {
        confess sprintf "child exited with value %d", $? >> 8;
    }
}

sub decompress {
    my($file,$destination) = @_;
    my($cmd,@opts);
    $cmd = 'tar' if $file =~ m/\.tar\b/;
    if( $cmd eq 'tar' ) {
        push @opts, '-x';
        push @opts, '-v' if $verbose;
        push @opts, '-z' if $file =~ m/\.gz\b/;
        push @opts, '-j' if $file =~ m/\.bz2\b/;
        push @opts, '-J' if $file =~ m/\.xz\b/;
        push @opts, '-C', $destination if $destination;
        push @opts, '-f', $file;
    }
    die "no program found to decompress: $file!\n" unless $cmd;
    safe_system($cmd,@opts);
}

sub cp {
    my $dest = pop;
    # TODO: deny access to root filesystem (on destination)
    foreach( map {glob $_} @_ ) {
        my $dest = $dest;
        $dest .= $& if -d $dest and $dest =~ m/\/$/ and m/[^\/]+$/;
        print "cp ".join(' ', map {s/ /\\ /g;$_} $_, $dest),"\n";
        File::Copy::copy($_, $dest) or die $!;
    }
}

sub cpR {
    my $dest = pop;
    $dest =~ s/\/+$//;
    # TODO: deny access to root filesystem (on destination)
    foreach( map {glob $_} @_ ) {
        my(@files) = ($_);
        my $basedir = m!^(.+)/[^/]+$! ? $1 : '';
        while( my $file = shift @files ) {
            $_ = $file;
            s/^$basedir\/?// or confess "fatal: source file $file"
                ." should start by $basedir!";
            my $dest = "$dest/$_";
            if( -f $file ) {
                cp $file, $dest;
            } elsif( -d (my $dir = $file) ) {
                die "error: can not copy a directory to a single file"
                    if -f $dest;
                opendir DIR, $dir
                    or die "error: can not open directory $dir: $!\n";
                while( my $file = readdir DIR ) {
                    next if $file =~ m/^\.\.?$/;
                    $file = "$dir/$file";
                    push @files, $file;
                }
                unless( -d $dest ) {
                    print "mkdir ".join(' ', map {s/ /\\ /g;$_} $dest),"\n";
                    mkdir $dest
                        or die "error: can not make directory $dest: $!";
                }
            }
        }
    }
}

sub chmodR {
    my $mode = shift;
    my @files = map {glob $_} @_;
    while( my $file = shift @files ) {
        my $mode = $mode;
        if( -d (my $dir = $file) ) {
            # read => execute
            $mode |= ($mode & 0444) >> 2;
            opendir DIR, $dir
                or die "error: can not open directory $dir: $!\n";
            while( my $file = readdir DIR ) {
                next if $file =~ m/^\.\.?$/;
                $file = "$dir/$file";
                push @files, $file;
            }
        }
        printf "chmod %o %s\n", $mode, $file;
        chmod $mode, $file;
    }
}

sub chownR {
    my $uid = shift;
    my $gid = shift;
    my @files = map {glob $_} @_;
    while( my $file = shift @files ) {
        if( -d (my $dir = $file) ) {
            opendir DIR, $dir
                or die "error: can not open directory $dir: $!\n";
            while( my $file = readdir DIR ) {
                next if $file =~ m/^\.\.?$/;
                $file = "$dir/$file";
                push @files, $file;
            }
        }
        printf "chown %d:%d %s\n", $uid, $gid, $file;
        chown $uid, $gid, $file;
    }
}

sub mv {
    my $dest = pop;
    # TODO: deny access to root filesystem
    foreach( map {glob $_} @_ ) {
        my $dest = $dest;
        #$dest .= "/$&" if -d $_ and $dest =~ m/\/$/ and m/[^\/]+$/;
        $dest .= $& if -d $dest and $dest =~ m/\/$/ and m/[^\/]+$/;
        print "mv ".join(' ', map {s/ /\\ /g;$_} $_, $dest)."\n";
        File::Copy::move($_, $dest) or die $!;
    }
}

sub ln {
    my($target,$link) = @_;
    print "ln -s ".join(' ', map {s/ /\\ /g;$_} $target, $link)."\n";
    symlink $_[0], $_[1] or die "error: can not link $_[0] to $_[1]: $!\n";
}

sub dd {
    my %o = (@_);
    $o{bs} = 512 unless $o{bs};
    $o{skip} = 0 unless $o{skip};
    $o{seek} = 0 unless $o{seek};
    $o{skip} *= $o{bs};
    $o{seek} *= $o{bs};
    $o{limit} = $o{limit} * $o{bs} - 1;
    open(my $in,'<',$o{if}) or die $!;
    binmode $in or die "error: can not read $o{if}: $!\n";
    open(my $out,(-f $o{of}?'+<':'>'),$o{of}) or die $!;
    binmode $out or die "error: can write on $o{of}: $!\n";
    seek $in,$o{skip},SEEK_SET;
    seek $out,$o{seek},SEEK_SET;

    my $count = 0;
    my $size = $o{bs};
    my $buf;
    while( not eof $in and (not defined $o{limit} or tell $out < $o{limit}) ) {
        if( $o{limit} ) {
            my $max = $o{limit} - tell $out;
            if( $max < $o{bs} ) {
                $size = $max;
                carp "uh oh, I tried to write too far" unless $o{nowarn};
            }
        }
        read $in,$buf,$size;
        print $out $buf;
        $count += $size;
    }
    print "$o{if}: $count bytes copied into $o{of} at $o{seek}\n";

    close $in;
    close $out;
}

sub convert_links {
    my @dirs = @_;
    while( my $dir = shift @dirs ) {
        $dir = realpath $dir;
        confess "fatal: $dir is not a directory" unless -d $dir;
        opendir DIR, $dir or die "error: can not open directory $dir: $!\n";
        while( my $file = readdir DIR ) {
            next if $file =~ m/^\.\.?$/;
            $file = "$dir/$file";
            if( -l $file ) {
                my $link = $file;
                my $path = readlink $link;
                next unless $path =~ s!^/!$target/!;
                my $rel_path = File::Spec->abs2rel(realpath($path), $dir);
                print "$rel_path -> $link\n";
                unlink $link or die "error: can not delete link $link: $!\n";
                symlink $rel_path, $link
                    or die "error: can not make symbolic link $link: $!\n";
            } elsif( -d $file ) {
                push @dirs, $file
            }
        }
    }
}

sub generate_pacman_conf {
    return if -f "pacman.conf";
    open IN,"$target/etc/pacman.conf"
        or die "error: can not read $target/etc/pacman.conf: $!\n";
    open OUT,">pacman.conf" or die "error: can not create pacman.conf: $!\n";
    while( <IN> ) {
        chop;
        s!/etc/pacman\.d/mirrorlist!$target$&!;
        $_="CacheDir = cache" if /CacheDir/;
        $_="RootDir = $target" if /RootDir/;
        $_="DBPath = $target/var/lib/pacman" if /DBPath/;
        print OUT "$_\n";
    }
    close OUT;
    close IN;
    mkdir 'cache';
}

sub pacman {
    generate_pacman_conf;
    safe_system(grep {$_}
        @pacman,'--noconfirm',
        ($debug ? '--debug' : undef),
        '--noscriptlet',
        #($verbose ? undef : '--quiet'),
        '--config',"pacman.conf",
        @_)
}

sub upgrade { pacman('-Syu') }

sub pacnew {
    my @files = @_ ? @_ : "$target/etc";
    while( my $file = shift @files ) {
        if( -f $file and $file =~ s/\.pacnew$// ) {
            unlink $file;
            mv "$file.pacnew", $file;
        } elsif( -d (my $dir = $file) ) {
            opendir DIR, $dir
                or die "error: can not open directory $dir: $!\n";
            while( my $file = readdir DIR ) {
                next if $file =~ m/^\.\.?$/;
                $file = "$dir/$file";
                push @files, $file;
            }
        }
    }
}

sub git {
    safe_system('git', @_);
}

sub mount {
    my $device = $device.$partition;
    confess "fatal: no device set" unless $device;
    mkpath $target;
    safe_system('mount', $device, $target);
}

sub umount {
    my $device = $device.$partition;
    confess "fatal: no device set" unless $device;
    safe_system('umount', $device);
}

sub hostname {
    confess "fatal: no hostname set" unless $hostname;
    open HOSTNAME,'>',"$target/etc/hostname"
        or die "error: can not open hostname file: $!\n";
    print HOSTNAME "$hostname\n";
    close HOSTNAME;
    print "hostname set to $hostname ...\n";
}

my $help;
GetOptions(
        "profile|p=s" => \$profile,
        "list|l" => \$list,
        "device|dev|d=s" => \$device,
        "partition|part=s" => \$partition,
        "target|t=s" => \$target,
        "custom|c=s" => \$custom,
        "ssh-key=s" => \$sshkey,
        "hostname=s" => \$hostname,
        "verbose|v" => \$verbose,
        "debug" => \$debug,
        "help|h" => \$help,
    ) or exit 1;

if( $list ) {
    my %profiles;
    foreach my $dir ( map {("$_/profile.d","$_/custom.d")} @INC ) {
        next unless -d $dir;
        opendir DIR, $dir;
        while( $_ = readdir DIR ) {
            next unless -f "$dir/$_";
            next if m/^\./;
            next if exists $profiles{$_};
            $profiles{$_} = "$dir/$_";
        }
    }
    while( my($profile,$path) = each %profiles ) {
        print "$profile at $path\n";
    }
    print STDERR "error: no profile found\n" unless %profiles;
    exit 0;
}
help if $help or not $profile or ($partition and not $device);

load_script 'profile.d', $profile;
load_script 'custom.d', $custom;

for my $p ( @ARGV ) {
    $p =~ tr/-/_/;
    die "fatal: procedure $p does not exists!\n"
        unless exists &{$p};
    die "fatal: procedure $p not exported!\n"
        unless grep {$p eq $_} @EXPORT_OK;
}

{
    no strict 'refs';
    @ARGV = ('all') unless @ARGV;
    for( @ARGV ) {
        tr/-/_/;
        print "$_:\n";
        &{$_};
    }
}

print "\nprogram ended normally\n";
