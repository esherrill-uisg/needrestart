# needrestart - Restart daemons after library updates.
#
# Authors:
#   Thomas Liske <thomas@fiasko-nw.net>
#
# Copyright Holder:
#   2013 - 2025 (C) Thomas Liske <thomas@fiasko-nw.net>
#
# License:
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this package; if not, write to the Free Software
#   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
#

package NeedRestart::Interp::Ruby;

use strict;
use warnings;

use parent qw(NeedRestart::Interp);
use Cwd qw(abs_path getcwd);
use File::Temp qw(tempdir);
use Getopt::Std;
use NeedRestart qw(:interp);
use NeedRestart::Utils;

my $LOGPREF = '[Ruby]';
my $empty_dir;

needrestart_interp_register(__PACKAGE__, "ruby");

sub isa {
    my $self = shift;
    my $pid = shift;
    my $bin = shift;

    return 1 if($bin =~ m@^/usr/(local/)?bin/ruby(\d[.\d]*)?$@);

    return 0;
}

sub _scan($$$$$) {
    my $debug = shift;
    my $pid = shift;
    my $src = shift;
    my $files = shift;
    my $path = shift;

    my $fh;
    open($fh, '<', "/proc/$pid/root/$src") || return;
    # find used modules
    my %modules = map {
	(/^\s*load\s+['"]([^'"]+)['"]/ ? ($1 => 1) : (/^\s*require\s+['"]([^'"]+)['"]/ ? ("$1.rb" => 1) : ()))
    } <$fh>;
    close($fh);

    # track file
    $files->{$src}++;

    # scan module files
    if(scalar keys %modules) {
	foreach my $module (keys %modules) {
	    foreach my $p (@$path) {
		my $fn = ($p ne '' ? "$p/" : '').$module;
		&_scan($debug, $pid, $fn, $files, $path) if(!exists($files->{$fn}) && -r $fn && -f $fn);
	    }
	}
    }
}

# chdir into empty directory to prevent ruby parsing arbitrary files
sub chdir_empty() {
    unless(defined($empty_dir)) {
        $empty_dir = tempdir(CLEANUP => 1);
    }
    chdir($empty_dir);
}

sub source {
    my $self = shift;
    my $pid = shift;
    my $ptable = nr_ptable_pid($pid);
    unless($ptable->{cwd}) {
	print STDERR "$LOGPREF #$pid: could not get current working directory, skipping\n" if($self->{debug});
	return undef;
    }
    my $cwd = getcwd();
    chdir("/proc/$pid/root/$ptable->{cwd}");

    # skip the process if the cwd is unreachable (i.e. due to mnt ns)
    unless(getcwd()) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: process cwd is unreachable\n" if($self->{debug});
	return undef;
    }

    # get original ARGV
    (my $bin, local @ARGV) = nr_parse_cmd($pid);

    # eat Ruby's command line options
    my %opts;
    {
	local $SIG{__WARN__} = sub { };
	getopts('SUacdlnpswvy0:C:E:F:I:K:T:W:e:i:r:x:e:d:', \%opts);
    }

    # skip ruby -e '...' calls
    if(exists($opts{e})) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: uses no source file (-e), skipping\n" if($self->{debug});
	return undef;
    }

    # extract source file
    unless($#ARGV > -1) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: could not get a source file, skipping\n" if($self->{debug});
	return undef;
    }

    my $src = abs_path($ARGV[0]);
    chdir($cwd);
    unless(defined($src) && -r $src && -f $src) {
	print STDERR "$LOGPREF #$pid: source file '$src' not found, skipping\n" if($self->{debug});
	print STDERR "$LOGPREF #$pid:  reduced ARGV: ".join(' ', @ARGV)."\n" if($self->{debug});
	return undef;
    }

    return $src;
}

sub files {
    my $self = shift;
    my $pid = shift;
    my $cache = shift;
    my $ptable = nr_ptable_pid($pid);
    unless($ptable->{cwd}) {
	print STDERR "$LOGPREF #$pid: could not get current working directory, skipping\n" if($self->{debug});
	return ();
    }
    my $cwd = getcwd();
    chdir("/proc/$pid/root/$ptable->{cwd}");

    # skip the process if the cwd is unreachable (i.e. due to mnt ns)
    unless(getcwd()) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: process cwd is unreachable\n" if($self->{debug});
	return ();
    }

    # get original ARGV
    (my $bin, local @ARGV) = nr_parse_cmd($pid);

    # eat Ruby's command line options
    my %opts;
    {
	local $SIG{__WARN__} = sub { };
	getopts('SUacdlnpswvy0:C:E:F:I:K:T:W:e:i:r:x:e:d:', \%opts);
    }

    # skip ruby -e '...' calls
    if(exists($opts{e})) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: uses no source file (-e), skipping\n" if($self->{debug});
	return ();
    }

    # extract source file
    unless($#ARGV > -1) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: could not get a source file, skipping\n" if($self->{debug});
	return ();
    }
    my $src = abs_path($ARGV[0]);
    unless(-r $src && -f $src) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: source file '$src' not found, skipping\n" if($self->{debug});
	print STDERR "$LOGPREF #$pid:  reduced ARGV: ".join(' ', @ARGV)."\n" if($self->{debug});
	return ();
    }
    print STDERR "$LOGPREF #$pid: source=$src\n" if($self->{debug});

    # use cached data if avail
    if(exists($cache->{files}->{(__PACKAGE__)}->{$src})) {
	chdir($cwd);
	print STDERR "$LOGPREF #$pid: use cached file list\n" if($self->{debug});
	return %{ $cache->{files}->{(__PACKAGE__)}->{$src} };
    }

    # prepare include path environment variable
    my @path;
    local %ENV;

    # get include path from env
    my %e = nr_parse_env($pid);
    if(exists($e{RUBYLIB})) {
	@path = split(':', $e{RUBYLIB});
    }

    # get include path
    chdir_empty();
    my $rbread = nr_fork_pipe($self->{debug}, $ptable->{exec}, '-e', 'puts $:');
    push(@path, <$rbread>);
    close($rbread);
    chomp(@path);
    chdir("/proc/$pid/root/$ptable->{cwd}");

    my %files;
    _scan($self->{debug}, $pid, $src, \%files, \@path);

    my %ret = map {
	my $stat = nr_stat("/proc/$pid/root/$_");
	$_ => ( defined($stat) ? $stat->{ctime} : undef );
    } keys %files;

    chdir($cwd);

    $cache->{files}->{(__PACKAGE__)}->{$src} = \%ret;
    return %ret;
}

1;
