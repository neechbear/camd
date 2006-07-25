#!/home/nicolaw/perl-5.8.8/bin/perl -w

use strict;
use threads;
use Thread::Queue;
use Proc::DaemonLite;
use Getopt::Std qw();
use POSIX qw(strftime);

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
	#my $resolution = $opts->{r} || '320x240';
	my $compression = $opts->{c} || 40;
	my $port = $opts->{P} || 80;
	my $imgurl = sprintf('http://%s:%d/axis-cgi/jpg/image.cgi?resolution=%s&compression=%d',
					$host, $port, '640x480', 5);

	for (;;) {
		if ($imgq->pending < 2) {
			eval {
				my $img = ProcessImage(LWP::Simple::get($imgurl),
						resolution => $resolution,
						compression => $compression,
					);
				$imgq->enqueue($img);
			};
			print $@ ? '{' : '<';
		} else {
			Time::HiRes::sleep($sleep_wait);
		}
	}
}

sub ProcessImage {
	my $img = shift;
	my $opt = { @_ };
	require Image::Magick;

	my $msg = `cat /tmp/caption 2>/dev/null` || '';
	my $quality = defined $opt->{compression} ? 100 - $opt->{compression} : 70;
	my ($width,$height) = defined $opt->{resolution} ? split(/\D+/,$opt->{resolution}) : (352,288);

	my $image = Image::Magick->new(magick => 'jpg');
	$image->BlobToImage($img);
	$image->Set(quality => $quality);
	$image->Set(type => "TrueColorMatte");
	$image->Resize(width => $width, height => $height);
	$image->Comment(sprintf('Copyright (c)%04d Nicola Worthington. All rights reserved.', (localtime(time))[5]+1900) );
# http://studio.imagemagick.org/pipermail/magick-users/2003-June/009442.html

	$image->Draw(
			stroke => '#666666',
			fill => '#ffffff',
			primitive => 'rectangle',
			points => sprintf('%d,%d %d,%d',0,0,$width-1,14),
		);

	$image->Draw(
			stroke => '#898E79',
			fill => '#898E79',
			primitive => 'rectangle',
			points => sprintf('%d,%d %d,%d',81,2,$width-3,12),
		);

	$image->Annotate(
			font => '/home/nicolaw/bin/Silkscreen.ttf',
			pointsize => 8,
			fill => '#ffffff',
			text => strftime('%Y-%m-%d %H:%M:%S',localtime),
			x => 85,
			y => 10,
		);

	$image->Annotate(
			font => '/home/nicolaw/bin/Silkscreen.ttf',
			pointsize => 8,
			align => 'right',
			fill => '#ffffff',
			text => uc($msg),
			x => $width-6,
			y => 10,
		);

	my $overlay = Image::Magick->new;
	$overlay->ReadImage('/home/nicolaw/bin/bisexual.png');
	$overlay->Set(type => "TrueColorMatte");
	$image->Composite(
			compose => 'over',
			image => $overlay,
			x => 0, y => 0,
			opacity => 50,
		);

	return $image->ImageToBlob;
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


