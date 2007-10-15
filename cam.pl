#!/usr/bin/perl -w

package Cam;

use constant COPYRIGHT         => sprintf('Copyright (c)%04d Nicola Worthington. All rights reserved.', (localtime(time))[5]+1900);
use constant IMAGE_FORMAT      => 'jpg';
use constant OVERLAY_IMAGE     => 'cam.png';

use constant ANNOTATE_IMAGE    => 1;
use constant ADD_TIMESTAMP     => 1;

use constant CAPTION_NOVIEWERS => 'PAUSED - PLEASE WAIT A MOMENT';
use constant CAPTION_FILE      => '/tmp/caption';
use constant CAPTION_FONT      => 'Silkscreen.ttf';
use constant CAPTION_COLOUR    => '#ffffff';
use constant CAPTION_BG_COLOUR => '#898E79';

use constant DEFAULT => {
		SOAP_SERVER_PORT  => 8021,               # SOAP server port
		SOAP_SERVER       => 'www.neechi.co.uk', # SOAP server hostname/IP
		SOAP_KEY          => 'ec2b5a007a8d0431a36ecadc815e9d82', # SOAP server key
		SOAP_CLIENT_ID    => 'jeneechipad',      # SOAP server client webcam ID
		WEBCAM_HOST       => 'webcam2',          # Webcam hostname/IP
		WEBCAM_PORT       => 80,                 # Webcam port
		WEBCAM_USERNAME   => 'cam_pl',           # Webcam username
		WEBCAM_PASSWORD   => 'ec2b5a00',         # Webcam password
		IMAGE_RESOLUTION  => '352x288',          # Resolution
		IMAGE_COMPRESSION => 30,                 # Compression %
		UPLOAD_FREQUENCY  => 0.05,               # Upload frequency
		CAPTION           => '',                 # Caption/message
		CROPPING          => undef,              # Crop
	};


##############################################################
#
#
#         NO USER SERVICABLE PARTS BEYOND THIS POINT!
#
#
##############################################################


use strict;
use threads;
use Thread::Queue;
use Proc::DaemonLite;
use Getopt::Std qw();
use POSIX qw(strftime uname);

# The following modules are loaded after this process has created
# all of its worker threads. This ensures that we don't have every
# module loaded in every thread, which saves a lot of memory.
#      Image::Magick
#      LWP::Simple
#      Time::HiRes
#      SOAP::Lite
#      FindBin

# Default command line options
my $opts = {
		p => DEFAULT->{SOAP_SERVER_PORT},
		s => DEFAULT->{SOAP_SERVER},
		k => DEFAULT->{SOAP_KEY},
		w => DEFAULT->{WEBCAM_HOST},
		P => DEFAULT->{WEBCAM_PORT},
		r => DEFAULT->{IMAGE_RESOLUTION},
		c => DEFAULT->{IMAGE_COMPRESSION},
		f => DEFAULT->{UPLOAD_FREQUENCY},
		m => DEFAULT->{CAPTION},
		C => DEFAULT->{CROPPING},
		i => DEFAULT->{SOAP_CLIENT_ID},
	};

# Parse command line options
Getopt::Std::getopts('hvdr:w:c:C:p:s:k:m:f:', $opts);
printf("%s %s\n",$0,'$Id$'), exit if defined $opts->{v};
printf("Syntax: %s [-h|-v] [-d] [-m <freeform message>]
        [-w <webcam host>] [-r <resolution>] [-c <compression>]
        [-s <server host>] [-p <port>] [-k <key>]
        [-i <client id>] [-f <upload frequency>]\n", $0), exit if defined $opts->{h};

# Daemonise
Proc::DaemonLite::init_server() if defined $opts->{d};

$| = 1;

my %threads = ();
my $imgq : shared = new Thread::Queue;
my $viewers : shared = 0;

# Create the worker threads
for my $sub (qw(GetImage SendImage)) {
	my $cref = eval("\\&$sub");
	print "Creating $sub thread ...\n";
	$threads{$sub} = new threads($cref, $sub, $opts);
}

for my $thread (threads->list) {
	$thread->join;
}

exit;



##############################
# Thread sub routines

sub GetImage {
	my ($sub,$opts) = @_;
	require Time::HiRes;

	my $imgurl = sprintf('http://%s:%d/axis-cgi/jpg/image.cgi?resolution=%s&compression=%d&date=0&text=0&showlength=1',
					$opts->{w}, $opts->{P}, '640x480', 0);

	for (;;) {
		if ($imgq->pending <= 1) {
			eval {
				if ($opts->{w} =~ m,^/dev/video\d*,i && -e $opts->{w} && -x '/usr/bin/vgrabbj') {
					#my $data = `/usr/bin/vgrabbj -q 100 -i sif -o jpg  -d $opts->{w} -g 2>/dev/null`;
					my $data = `/usr/bin/vgrabbj -q 100 -i sif -g -o jpg -d $opts->{w} 2>/dev/null`;
					my $img = ProcessImage($data, $opts);
					$imgq->enqueue($img);

				} else {
					my $ua = new LWP::UserAgent2;
					my $resp = $ua->get($imgurl);
					if ($resp->is_success) {
						my $img = ProcessImage($resp->content, $opts);
						$imgq->enqueue($img);
					} else {
						die $resp->status_line;
					}
				}
			};
			warn $@ if $@;
			print $@ ? '{' : '<';
		} else {
			Time::HiRes::sleep($opts->{f});
		}
	}
}


sub ProcessImage {
	my ($img,$opts) = @_;
	require Image::Magick;
	require FindBin;

	my $caption_file = CAPTION_FILE;
	my $msg = $opts->{m};
	if (-f $caption_file && open(MSG,'<',$caption_file)) {
		$msg = <MSG>; chomp $msg;
		close(MSG);
	}
	$msg = CAPTION_NOVIEWERS if !$viewers;

	my $font = "$FindBin::Bin/".CAPTION_FONT;
	my $quality = defined $opts->{c} ? 100 - $opts->{c} : 70;
	my ($width,$height) = defined $opts->{r} ? split(/\D+/,$opts->{r}) : (352,288);

	my $image = Image::Magick->new(magick => IMAGE_FORMAT);
	$image->BlobToImage($img);
	$image->Set(quality => $quality);
	$image->Set(type => "TrueColorMatte");

	if (defined $opts->{C} && $opts->{C}) {
		# TODO
		# This is not extracting the information from
		# $opts->{C} yet when it should be.
		$image->Crop(x=>130, y=>100, width => 480, height=>360);
	}
	$image->Resize(width => $width, height => $height);

	$image->Comment(COPYRIGHT);
	# http://studio.imagemagick.org/pipermail/magick-users/2003-June/009442.html

	if (ANNOTATE_IMAGE) {
		# Draw annotation background
		$image->Draw(
				stroke    => '#666666',
				fill      => CAPTION_COLOUR,
				primitive => 'rectangle',
				points    => sprintf('%d,%d %d,%d',0,0,$width-1,14),
			);
		$image->Draw(
				stroke    => CAPTION_BG_COLOUR,
				fill      => CAPTION_BG_COLOUR,
				primitive => 'rectangle',
				points    => sprintf('%d,%d %d,%d',81,2,$width-3,12),
			);

		# Add timestamp
		$image->Annotate(
				font      => $font,
				pointsize => 8,
				fill      => CAPTION_COLOUR,
				text      => strftime('%Y-%m-%d %H:%M:%S',localtime),
				x         => 85,
				y         => 10,
			) if ADD_TIMESTAMP;

		# Add caption message
		$image->Annotate(
				font      => $font,
				pointsize => 8,
				align     => 'right',
				fill      => CAPTION_COLOUR,
				text      => uc($msg),
				x         => $width-6,
				y         => 10,
			) if defined $msg && $msg =~ /\S+/;
	}

	# Add image overlay
	my $overlay_file = "$FindBin::Bin/".OVERLAY_IMAGE;
	if (defined OVERLAY_IMAGE && -f $overlay_file) {
		my $overlay = Image::Magick->new;
		$overlay->ReadImage($overlay_file);
		$overlay->Set(type => "TrueColorMatte");
		$image->Composite(
				compose => 'over',
				image   => $overlay,
				x       => 0,
				y       => 0,
				opacity => 50,
			);
	}

	return $image->ImageToBlob;
}


sub SendImage {
	my ($sub,$opts) = @_;
	require SOAP::Lite;

	# TODO
	# Need to change this so that the client and server send and
	# recieve properly named key/value pairs to aid debugging and
	# readability of the code.
	my $soap = SOAP::Lite->new(
			uri => "http://$opts->{s}/WebCam/Server/",
			proxy => "http://$opts->{s}:$opts->{p}",
		);

	while (my $imgbin = $imgq->dequeue) {
		eval {
			my $results = $soap->store_image($opts->{k},$imgbin,$opts->{m},$opts->{i})->result || {};
			$viewers = $results->{sleep} > 1 ? 0 : 1;
			print $results->{bytes_written} ? '>' : '}';
			sleep $results->{sleep} if
				defined $results->{sleep} && $results->{sleep} =~ /^\d+$/;
		};
		warn "SendImage(): $@\n", sleep 1 if $@;
	}
}


package LWP::UserAgent2;
use base qw(LWP::UserAgent);

sub get_basic_credentials {
	return (
			Cam::DEFAULT->{WEBCAM_USERNAME},
			Cam::DEFAULT->{WEBCAM_PASSWORD}
		);
}

__END__



