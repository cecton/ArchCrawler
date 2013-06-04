#!/usr/bin/env perl

use strict;
use warnings;

use Carp;
use Getopt::Long;
use POSIX qw/strftime/;
use LWP::UserAgent;
use base qw/File::Path File::Copy/;

die "error: this program need to be run as root.\n"
    unless $> == 0;

our @BASE_EXPORT_OK = qw/upgrade all/;
our $profile;
our $list;
our $device;
our $target = 'target';
our $verbose;
our $arch = `uname -m`;

our $ua = LWP::UserAgent->new;

sub help {
    my $included_paths = join("\n", map {"    $_"} @INC);
    print <<EOF;
ArchCrawler - Arch Deployment script

Usage: $0
    <--profile=PROFILE|-p PROFILE> [<--list|-l>]
    [<--target TARGET|-t TARGET>] [<--device DEVICE|--dev DEVICE|-d DEVICE>]
    [<--verbose|-v>] [<--help|-h>]

Arguments:

    PROFILE     must be found in profile.d directory in included paths
    TARGET      target directory (mount point of the root filesystem
                default: ./target
    DEVICE      target device to install the system

Parameters:

    --list, -l
        list all existing profiles
    --verbose, -v
        verbose mode
    --help, -h
        this help

Included paths:
$included_paths

EOF
    exit 0
}

sub human_size
{
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
    File::Path::rmtree @_, {verbose => $verbose} or die "$!\n";
}

sub mkpath {
    # TODO: deny access to root filesystem
    File::Path::mkpath @_, {verbose => $verbose} or die "$!\n";
}

sub safe_system {
    system(@_);
    if( $? == -1 ) {
        die "failed to execute!\n";
    } elsif ($? & 127) {
        printf "child died with signal %d, %s coredump\n",
            ($? & 127),  ($? & 128) ? 'with' : 'without';
        exit 1;
    } elsif( $? >> 8 != 0 ) {
        printf "child exited with value %d\n", $? >> 8;
        exit 1;
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
    print join(' ', map {s/ /\\ /g;$_} $cmd, @opts),"\n";
    safe_system($cmd,@opts);
}

sub cp {
    my $dest = pop;
    # TODO: deny access to root filesystem (on destination)
    foreach( map {glob $_} @_ ) {
        my $dest = $dest;
        $dest .= "/$&" if -d $_ and $dest =~ m/\/$/ and m/[^\/]+$/;
        print "mv ".join(' ', map {s/ /\\ /g;$_} $_, $dest),"\n";
        File::Copy::copy($_, $dest) or die $!;
    }
}

sub mv {
    my $dest = pop;
    # TODO: deny access to root filesystem
    foreach( map {glob $_} @_ ) {
        my $dest = $dest;
        $dest .= "/$&" if -d $_ and $dest =~ m/\/$/ and m/[^\/]+$/;
        print "mv ".join(' ', map {s/ /\\ /g;$_} $_, $dest),"\n";
        File::Copy::move($_, $dest) or die $!;
    }
}

sub generate_pacman_conf {
    return if -f "pacman.conf";
    open IN,"$target/etc/pacman.conf"
        or die "error: can not read $target/etc/pacman.conf: $!\n";
    open OUT,">pacman.conf" or die "error: can not create pacman.conf: $!\n";
    while( <IN> ) {
        s!/etc/pacman\.d/mirrorlist!$target$&!;
        print OUT $_;
    }
    close OUT;
    close IN;
}

sub pacman {
    generate_pacman_conf;
    safe_system(grep {$_}
        'pacman','--noconfirm','--arch',$arch,
        ($verbose ? '--quiet' : undef),
        '-b',"$target/var/lib/pacman",
        '-r',$target,
        '--config',"pacman.conf",
        @_)
}

sub upgrade { pacman('-Syu') }

sub mount {
    confess "fatal: no device set" unless $device;
    safe_system('mount', @_);
}

sub unmount {
    confess "fatal: no device set" unless $device;
    safe_system('unmount', @_);
}

my $help;
GetOptions(
        "profile|p=s" => \$profile,
        "list|l" => \$list,
        "device|dev|d=s" => \$device,
        "target|t=s" => \$target,
        "verbose|v" => \$verbose,
        "help|h" => \$help,
    ) or exit 1;

help if $help or not $profile;
if( $list ) {
    my %profiles;
    foreach my $dir ( map {"$_/profiles.d"} @INC ) {
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

{
    my $file;
    foreach( map {"$_/profiles.d/$profile"} @INC ) {
        next unless -f $_;
        $file = $_;
    }
    die "error: can not find profile $profile\n" unless $file;
    local $/;
    open PROFILE,$file or die $!;
    my $code = <PROFILE>;
    close PROFILE;
    eval $code;
    die $@ if $@;
    undef $@;
    die "error: no global variable \@EXPORT_OK set\n"
        unless @main::EXPORT_OK;
}

for my $p ( @ARGV ) {
    die "fatal: procedure $p does not exists!\n"
        unless exists &{$p};
    die "fatal: procedure $p not exported!\n"
        unless grep {$p eq $_} @main::EXPORT_OK, @BASE_EXPORT_OK;
}

{
    no strict 'refs';
    @ARGV = ('all') unless @ARGV;
    &{$_} for @ARGV;
}
