#!/home/nicolaw/perl-5.8.8/bin/perl -w

use strict;
use threads;
use Thread::Queue;
use Proc::DaemonLite;
use Getopt::Std qw();

my $opts = {};
Getopt::Std::getopts('hvdr:w:c:p:s:k:m:', $opts);
printf("%s %s\n",$0,'$Id$'), exit if defined $opts->{v};
printf("Syntax: %s [-h|-v] [-d] [-m <freeform message>]
        [-w <webcam host>] [-r <resolution>] [-c <compression>]
        [-s <server host>] [-p <port>] [-k <key>]\n", $0), exit if defined $opts->{h};

init_server() if defined $opts->{d};

$| = 1;

my %threads = ();
my $imgq : shared = new Thread::Queue;

for my $sub (qw(GetImage SendImage)) {
	my $cref = eval("\\&$sub");
	print "Creating $sub thread ...\n";
	$threads{$sub} = new threads($cref, $sub, $opts);
}

for my $thread (threads->list) {
	$thread->join;
}

exit;

sub GetImage {
	my ($sub,$opts) = @_;
	require LWP::Simple;
	require Time::HiRes;

	my $sleep_wait = 0.25;
	my $host = $opts->{w} || 'webcam.tfb.net';
	my $resolution = $opts->{r} || '352x288';
	my $compression = $opts->{c} || 50;
	my $port = $opts->{P} || 80;
	my $imgurl = sprintf('http://%s:%d/axis-cgi/jpg/image.cgi?resolution=%s&compression=%d',
					$host, $port, $resolution, $compression);

	for (;;) {
		if ($imgq->pending < 2) {
			eval { $imgq->enqueue(LWP::Simple::get($imgurl)); };
			print $@ ? '{' : '<';
		} else {
			Time::HiRes::sleep($sleep_wait);
		}
	}
}

sub SendImage {
	my ($sub,$opts) = @_;
	require SOAP::Lite;

	my $port = $opts->{p} || 8021;
	my $server = $opts->{s} || 'www.neechi.co.uk';
	my $key = $opts->{k} || 'ec2b5a007a8d0431a36ecadc815e9d82';
	my $msg = $opts->{m} || '';

	my $soap = SOAP::Lite->new(
			uri => "http://$server/WebCam/Server/",
			proxy => "http://$server:$port",
		);

	while (my $imgbin = $imgq->dequeue) {
		eval {
			my $results = $soap->store_image($key,$imgbin,$msg)->result || {};
			print $results->{bytes_written} ? '>' : '}';
			sleep $results->{sleep} if
				defined $results->{sleep} && $results->{sleep} =~ /^\d+$/;
		};
		warn "SendImage(): $@\n", sleep 1 if $@;
	}
}

__END__


