#!/home/nicolaw/webroot/perl-5.8.7/bin/perl -w

use strict;
use threads;
use threads::shared;
use Proc::DaemonLite;
use Getopt::Std qw();

my $opts = {};
Getopt::Std::getopts('hvsdb:p:l:', $opts);
printf("%s %s\n",$0,'$Id$'), exit if defined $opts->{v};
printf("Syntax: %s [-h|-v] [-d] [-l <apache log>]
        [-b <bind host>] [-p <port>]\n", $0), exit if defined $opts->{h};

init_server() if defined $opts->{d};

$| = 1;

my %threads = ();
my $activity : shared = 0;

for my $sub (qw(TailLog SoapServer)) {
	my $cref = eval("\\&$sub");
	print "Creating $sub thread ...\n";
	$threads{$sub} = new threads($cref, $sub, $opts);
}

for my $thread (threads->list) {
	$thread->join;
}

exit;

sub TailLog {
	my ($sub,$opts) = @_;
	require File::Tail;

	my $timeout = 15;
	my $last_seen = time;
	my $matchregex = qw(webcam\.jpg);
	my @weblogs = defined $opts->{l} ? split(/\s*:\s*/,$opts->{l}) :
			('/home/nicolaw/webroot/logs/www.neechi.co.uk/access.log');

	my @tails = map { File::Tail->new(
			'name' => $_,
			'maxinterval' => 10,
			'interval' => 2,
			'adjustafter' => 10,
			'reset_tail' => 10,
			'ignore_nonexistant' => 1,
		); } @weblogs;

	for (;;) {
		my ($nfound,$timeleft,@pending) =
			File::Tail::select(undef,undef,undef,$timeout,@tails);
		unless ($nfound) {
			$activity = 0;
		} else {
			foreach (@pending) {
				if ($_->read =~ /$matchregex/) {
					$last_seen = time;
					$activity = 1;
				} else {
					$activity = 0 if time - $last_seen > $timeout;
				}
			}
		}
	}
}

sub SoapServer {
	my ($sub,$opts) = @_;
	require SOAP::Transport::HTTP;

	my $daemon = SOAP::Transport::HTTP::Daemon->new(
			LocalAddr => $opts->{h} || 'www.neechi.co.uk',
			LocalPort => $opts->{p} || 8021,
		);

	$daemon->dispatch_to('WebCam::Server');

	print "Contact to SOAP server at ", $daemon->url, "\n";
	$daemon->handle;
}


package WebCam::Server;

sub store_image {
	my $class = shift;

	my $key = 'ec2b5a007a8d0431a36ecadc815e9d82';
	return {} unless $_[0] eq $key;

	my $imgdir = '/tmp/webcam';
	my $keep = 20;
	my $inactivity_sleep = 10;
	my $linkfrom = '/home/nicolaw/webroot/www/www.neechi.co.uk/webcam/webcam.jpg';
	my $destfile = "$imgdir/cam.jpg";
	my $tmpfile = "$destfile.".time().$$;

	mkdir $imgdir unless -d $imgdir;
	unlink $linkfrom unless -l $linkfrom;
	symlink $destfile, $linkfrom unless -e $linkfrom;

	require File::Slurp;
	File::Slurp::write_file($tmpfile, {binmode => ':raw' }, $_[1]);

	my $bytes_written = (stat($tmpfile))[7] || 0;
	my $bytes_received = length($_[1]) || 0;
	if ($bytes_written == $bytes_received) {
		rotate_images($tmpfile,$destfile,$imgdir,$keep);
	}

	File::Slurp::write_file("$destfile/message.txt", $_[2])
		if defined $_[2] && $_[2] =~ /\S+/;

	my $return = {
			'keep' => $keep,
			'tmpfile' => $tmpfile,
			'destfile' => $destfile,
			'linkfrom' => $linkfrom,
			'bytes_written' => $bytes_written,
			'bytes_received' => $bytes_received,
			'time' => time(),
			'sleep' => $activity ? 0 : $inactivity_sleep,
		};

	return $return;
}

sub rotate_images {
	my ($tmpfile,$destfile,$imgdir,$keep) = @_;

	unlink "$destfile.$keep" if -f "$destfile.$keep";
	for (my $i = $keep - 1; $i >= 1; $i--) {
		next unless -f "$destfile.$i";
		my $archfile = sprintf("$destfile.%s", $i+1);
		rename "$destfile.$i", $archfile;
	}

	rename $destfile, "$destfile.1" if -f $destfile;
	rename $tmpfile, $destfile;
}

__END__


