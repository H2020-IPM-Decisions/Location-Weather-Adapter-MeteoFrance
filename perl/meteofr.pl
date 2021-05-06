#!/usr/bin/perl 
use strict;
use File::stat;

my $lockfile       = ".lockfile";  # process lock file
my $regfile        = ".register";  # register file keeps track of downloaded files
my $verbose=0;
my $myname=$0;
# avvoid duplicate processing...
if (-e $lockfile) { # something is fishy...
    # this changes ctime and mtime, but not atime...
    open(MLOCKFILE, ">$lockfile") 
        or die("Couldn't open Lockfile: '$lockfile'.\n");
    die "$lockfile already locked\n" unless (flock (MLOCKFILE,2+4));
    # ...hmm, lockfile is not flocked. Location could be virtual...
    # Remove lockfile if it is old.
    my $sb= stat($lockfile);
    my $age=(time() - $sb->atime)/3600; # hours
    #print("Lock file age: $age ($lockfile) ".(time())."\n");
    #die"Hard";
    if ($age > 0.10) {unlink($lockfile);print ">>>> Old $lockfile removed (".sprintf("%.2f",$age)."h).\n"; }; # abort if lockfile is newer than 0.25 hours...
    if (-e $lockfile) {die "$lockfile is too new to ignore (".sprintf("%.2f",$age)."h)."};
};
# lockfile should not exist at this point...
open(MLOCKFILE, ">$lockfile") 
    or die("Couldn't open Lockfile: '$lockfile'.\n");
die "$lockfile already locked\n" unless (flock (MLOCKFILE,2+4));



# get capability file
my $url="https://donneespubliques.meteofrance.fr/inspire/services/MF-NWP-HIGHRES-AROME-001-FRANCE-WCS/?request=GetCapabilities&service=WCS";
my $cmd="curl -o - \"$url\"";
print(">>> Command:$cmd\n");
my $capabilities=`$cmd`;

# extract server information
my $server;
if ($capabilities =~ m/\<ows:Operation name="GetCapabilities"\>.*"(.*)".*<\/ows:Operation\>/s) {
    $server = $1;
}

#get possible parameters / analysis

my @plist=$capabilities=~m/\<wcs:CoverageId\>([^\<\>]*)\<\/wcs:CoverageId\>/g;

# get interesting parameters

my @masks= ("^TEMPERATURE__","^RELATIVE_HUMIDITY__","^TOTAL_PRECIPITATION__.*_PT1H","^WIND_SPEED__","^PRESSURE__");
#my @masks= ("^TOTAL_PRECIPITATION__.*_P1D"); # dette er nok mm "per 1 day"...
#my @masks= ("^BRIGHTNESS_TEMPERATURE__"); # denne fungerer ikke

# get latest analysis
my $latest;
my @relevant=();
open(FH, '>', "list_of_capabilities.txt"); 
print(">>> list of parameters:\n");
foreach my $dd (@plist) {
    print ("       $dd\n");
    print FH $dd . "\n";
    if (scalar @masks > 0) {
	foreach my $mask (@masks) {
	    if ($dd =~ m/$mask/) {
		if ($dd =~ m/^(.*___)(\d{4})\-(\d{2})\-(\d{2})T(\d{2})\.(\d{2})\.(\d{2})Z(.*)$/) {#.*___2021-03-15T00.00.00Z
		    my $ana="$2-$3-$4T$5:$6:$7Z";
		    if ($latest==undef || $latest lt $ana) { 
			$latest=$ana;
		    };
		};
		push(@relevant,$dd);
		last;
	    }
	}
    } else { # no mask, get all
	if ($dd =~ m/^(.*___)(\d{4})\-(\d{2})\-(\d{2})T(\d{2})\.(\d{2})\.(\d{2})Z(.*)$/) {#.*___2021-03-15T00.00.00Z
	    my $ana="$2-$3-$4T$5:$6:$7Z";
	    if ($latest==undef || $latest lt $ana) { 
		$latest=$ana;
	    };
	};
	push(@relevant,$dd);
    }
}
close FH;

my $lastana = getRegister($regfile);
if ($lastana eq $latest) {
    print(">>> Same analysis as last time ($lastana==$latest)...\n");
} else {
    print(">>> Processing new analysis ($lastana!=$latest)...\n");
    setRegister($regfile,$latest);

    # loop over files
    my $token="__5UhNYRvv5LmgDzJr6iGeWgR-ZXdicmOt__";
    my $pref="SERVICE=WCS&VERSION=2.0.1&REQUEST=GetCoverage&format=application/wmo-grib&coverageId=";
    my $post="&subset=lat(36.6123046875,56.3876953125)&subset=long(-13.8642578125,17.8642578125)";
    my $files="";
    if ($server =~ m/^(.*api\/)(\/.*)$/) {
	my $ss=$1; # before token
	my $pp=$2; # after token
	my %heights;
	my %suffixes;
	print(">>> Latest analysis: $latest\n");
	# get parameters with latest analysis
	foreach my $dd (@relevant) {
	    # get analysis time
	    if ($dd =~ m/^(.*___)(\d{4})\-(\d{2})\-(\d{2})T(\d{2})\.(\d{2})\.(\d{2})Z(.*)$/) {#.*___2021-03-15T00.00.00Z
		my $par=$1;
		my $ana="$2-$3-$4T$5:$6:$7Z";
		if ($latest==$ana) { 
		    $suffixes{$par}=$8;
		    if ($par =~ m/SPECIFIC_HEIGHT_LEVEL_ABOVE_GROUND/) {
			if ($par =~ m/WIND/) {
			    $heights{$par}="&subset=height(10)";
			} else {
			    $heights{$par}="&subset=height(2)";
			};
		    } else {
			$heights{$par}="";
		    }
		};
	    }
	};
	# loop over parameters that have the latest analysis
	foreach my $par (keys %heights) {
	    my $height=$heights{$par};
	    my $suffix=$suffixes{$par};
	    my $dd=$par . $latest . $suffix;
	    # make invalid probe url to get valid times
	    my $fc="2000-01-01T00:00:00Z";
	    my $purl="$ss$token$pp$pref$dd&subset=time($fc)$post$height";
	    $cmd="curl -o - \"$purl\"";
	    print(">>> Command:$cmd\n");
	    my $bbok=0;
	    my $ttry=0;
	    while (! $bbok) {
		$ttry=$ttry+1;
		my $tlist=`$cmd`;
		print ($tlist);
		# extract valid forecast times
		my $cnt=0;
		$fc="";
		while ($tlist=~m/(\d{4}).(\d{2}).(\d{2})T(\d{2}).(\d{2}).(\d{2})Z/g) {
		    $cnt=$cnt+1;
		    my $fc="$1-$2-$3T$4:$5:$6Z";
		    # create valid url to get grib2 file
		    my $furl="$ss$token$pp$pref$dd&subset=time($fc)$post$height";
		    # temporary segment file
		    my $file="segment_$par$cnt.grib2";
		    print ("Temporary file: $file\n");
		    # get grib2 file
		    $cmd="curl -o $file \"$furl\"";
		    my $try=0;
		    my $bok=0;
		    while (! $bok) {
			$try=$try+1;
			print(">>> Command:$cmd\n");
			system ($cmd);
			if (open(FILE1, $file)) {
			    my ($file4);
			    read(FILE1,$file4,4);
			    print (">>> file: $file => $file4\n");
			    if ( "$file4" eq "GRIB") {
				$bok=1;
			    } else {
				sleep(0.5);
			    }
			    close(FILE1);
			} else {
			    print (">>> File failed: $file\n");
			    $bok=1;
			}
			if (! $bok && $try > 5) {
			    print (">>> No more tries...\n");
			    $bok=1;
			} elsif ($bok) {
			    $files=$files . " " . $file;
			}
		    }
		    $bbok=1;
		}
		if (! $bbok) {
		    if ($ttry > 5) {
			print (">>> Parameter failed: $par");
			$bbok=1;
		    } else {
			sleep(0.5);
		    }
		}
	    }
	}
    } else {
	print ">>> Unable to locate server in capability reply:\n$capabilities\n";
    }
    # concatenate files to output grib2 file
    if ($files) {
	$cmd="cat $files > all.grib2";
	print(">>> Command:$cmd\n");
	system ($cmd);
	$cmd="fimex-1.6 --input.file all.grib2 --input.config cdmGribReaderConfig.xml --output.file all.nc";
	print(">>> Command:$cmd\n");
	system ($cmd);
    } else {
	print(">>> No files were downloaded...\n");
    }
};

# Unlock lock-file...
close LOCKFILE;
unlink($lockfile) || print(">>>> Unable to remove $lockfile\n");

#==============================================
#  End task.
#==============================================

sub getRegister {
    my $registerfile=shift;
    # Load register from local register file 
    if ($verbose) {print ">>>> Reading register file: $registerfile\n";}
    if (not open(REGISTER, "<$registerfile")) { 
	my $subject = "$myname: Unable to open $registerfile";
	my $reason = '';
	print (">>> $subject\n");
	#Email($reason,$subject, @owners);
	#	 SendEmail();
	#	 die "$subject";
    }
    while (<REGISTER>) {
	chomp;
	my $line=$_;
	return $line;
    }
    close REGISTER;
    return;
}

sub setRegister {
    my $registerfile=shift;
    my $line=shift;
    if ($verbose) {print ">>>> Writing register file: $registerfile\n";}
    if (not open (REGISTER,">$registerfile")) {
	my $subject = "$myname: Unable to open $registerfile";
	my $reason = '';
	print (">>> $subject\n");
	#Email($reason,$subject, @owners);
	#	 SendEmail();
	#	 die "$subject\n";
    }
    if ($verbose > 1) {print(">>>> New register $registerfile\n");}
    print REGISTER $line . "\n";
    close REGISTER;
};

# sub Email {
#     my ($reason,$subject, @owners) = @_;
#     for my $owner ( @owners ) {
# 	$Mail{$owner} .= "$subject\n";
# 	$Mail{$owner} .= "  Reason=$reason\n" if ($reason);
#     }
# }

# sub SendEmail {
#     for my $owner ( keys %Mail ) {
# 	if ($verbose) {print ">>>> Sending e-mail to  $owner\n";}
# 	open(MH,"|/usr/bin/Mail -s \'Warnings from $user running $myname at $host\' $owner") || die "Could not mail\n";
# 	print MH $Mail{$owner};
# 	close(MH);
#     }
# }
