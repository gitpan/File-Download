#!/usr/bin/perl
use 5.006_001; use 5.6.1;	
use strict;
use warnings;

package File::Download;
=pod
# use base 'Class::Accessor';
# Class::Accessor doesn't appear to work properly in Perl >5.6.
# This may be because "my" variable declarations in the accessors are not visible outside.

# our ($VERSION, @EXPORT_OK, %EXPORT_TAGS, $DEBUG);
## __PACKAGE__->mk_constructor;
# __PACKAGE__->mk_accessors(qw(mode DEBUG overwrite outfile flength size user_agent file status username password length start_t last_dur autodelete));
# __PACKAGE__->mk_ro_accessors(qw(VERSION));
# $File::Download::DEBUG = 0;
# $File::Download::VERSION = '0.4_050601'; #perl 5.6.1 version May, 2015 Matt Pagel
=cut

use Class::Accessor::Constructor 'antlers'; # Switching to 'antler' mode. Also need a "new" constructor.

has 'DEBUG' => (is => 'rw');
has 'file' => (is => 'rw');
has 'outfile' => (is => 'rw');
has 'overwrite' => (is => 'rw');
has 'user_agent' => (is => 'rw');
has 'username' => (is => 'rw');
has 'password' => (is => 'rw');
has 'autodelete' => (is => 'rw'); #probably tied to overwrite
has 'mode' => (is => 'rw'); # 'b' for binary, 'a' for ASCII
has 'result' => (is => 'rw'); # Provides access to the result of the 
has 'completion_status' => (is => 'rw'); #0 is not yet initiated; #1 when the filenames have been determined and we are good to go. #2 when done

# has 'VERSION' => (is => 'ro'); # Don't need this - set via explicit definition. Otherwise cpan won't compile it right.

# I really don't want to expose the below, but perl complains if these are 'ro' and I try to set the values internally. Declaring with 'our' doesn't seem an option either.
# Suggestions for a better set of implementations would be appreciated. Package these into a single list tied together as an "our" variable?
has 'flength' => (is => 'rw'); # would rather have this inaccessible and thus set to 'ro' (see above)
has 'size' => (is => 'rw'); # see above
has 'status' => (is => 'rw'); # see above
has 'length' => (is => 'rw'); # see above
has 'start_t' => (is => 'rw'); # see above
has 'last_dur' => (is => 'rw'); # see above
has 'local_file_name' => (is => 'rw'); # see above
has 'local_dir_path' => (is => 'rw'); # see above

use constant DEFAULTS => #used by the constructor
    (#VERSION => '0.4_050601',
     DEBUG => 0,
     overwrite => 1,
     flength => 0,
     status => 'not started',
     username => 'not supported',
     password => 'not supported',
     start_t => 0,
     last_dur => 0,
     autodelete => 0,
     completion_status => 0,
     mode => 'b'
     );

$FILE::DOWNLOAD::VERSION = '0.4_050601' unless defined $FILE::DOWNLOAD::VERSION; #perl 5.6.1 version May, 2015 Matt Pagel

__PACKAGE__->mk_constructor;
# __PACKAGE__->{DEBUG} = 0; #probably already set. Also of limited use in current code state.

use LWP::UserAgent (); #include, but require explicit reference to functions inside to use
use LWP::MediaTypes qw(guess_media_type media_suffix);
use URI ();
use HTTP::Date ();
use File::Spec ();

sub DESTROY { }

$SIG{INT} = sub { die "Interrupted\n"; };

$| = 1;  # autoflush

sub set_local_filename  {
    #call this with $self->set_local_filename internally
    my $self = shift;
    our ($res, $url);
    my $lclout;
    my ($vol, $dir);
    $self->{local_dir_path} = undef; #don't trust the end-user
    $self->{local_file_name} = undef;
    if (defined $self->{outfile}) {
        $lclout = File::Spec->rel2abs($self->{outfile}); #if already an absolute path, it'll clean this up
        ($vol, $dir, $self->{local_file_name}) = File::Spec->splitpath($lclout);
#        $self->{status} .= sprintf("vol:%s dir:%s name:%s\n",$vol, $dir, $self->{local_file_name});
        if ($self->{local_file_name} eq '') { #outfile was a directory name...it may or may not exist
            $self->{local_dir_path} = $lclout;
        } else {
            if (-d $lclout) { $self->{local_dir_path} = $lclout; $self->{local_file_name} = '' }
            else { $self->{local_dir_path} = File::Spec->catpath($vol, $dir, '') }#or undef?
        }
        unless (-d $self->{local_dir_path}) { die ("$self->{local_dir_path} from $self->{outfile} is not an existing direcory") };
    }
    $lclout = $self->{local_file_name};
    unless (defined $lclout && length($lclout)) { #$outfile wasn't defined in the block to follow
    # find a suitable name to use
        $self->{status} .= "outfile not defined\n";
        $lclout = $res->filename; #look for header tag that defines tag
    		# if this fails we try to make something from the URL
        unless ($lclout) {
            $self->{status} .= "file name not defined in header\n";
    		my $req = $res->request;  # not always there
    		my $rurl = $req ? $req->url : $url;
    		$lclout = ($rurl->path_segments)[-1];
            if (!defined($lclout) || !length($lclout)) {
        		$lclout = "index";
        		my $suffix = media_suffix($res->content_type);
        		$lclout .= ".$suffix" if $suffix;
    		} elsif ($rurl->scheme eq 'ftp' ||
                     $lclout =~ /\.t[bg]z$/   ||
                     $lclout =~ /\.tar(\.(Z|gz|bz2?))?$/
                    ) { #do nothing else to the name
            } else {
                $self->{status} .= "guessing media type\n";
                my $ct = guess_media_type($lclout);
        		unless ($ct eq $res->content_type) {
        			# need a better suffix for this type
        			my $suffix = media_suffix($res->content_type);
                    $lclout .= ".$suffix" if $suffix;
        		}
    		}
        }
    } #even if it was previously defined, we should probably do these checks...unless the download has already started and connection is valid
    if ($self->{completion_status} == 0) {
        # validate that we don't have a harmful local filename now.  The server
    	# might try to trick us into doing something bad.
        if ($lclout && !length($lclout) || $lclout =~ s/([^a-zA-Z0-9_\.\-\+\~])/sprintf "\\x%02x", ord($1)/ge) {
            die "Will not save <$url> as \"$lclout\".\nPlease override file name on the command line.\n";
        } if (defined $self->{local_dir_path}) {
            $self->{status} .= "output directory specified\n";
    		$lclout = File::Spec->catfile($self->{local_dir_path}, $lclout); #the variable now has a full path
        } else {
            #we're good...the variable was just a filename to begin with.... Do nothing
        }
 		# Check if the file is already present
        if (-l $lclout) {
    		die "Will not save <$url> to link \"$lclout\".\nPlease change filename.\n";
        } elsif (-f _) { #if it's a plain file...whatever that is
    		die "Will not save <$url> as \"$lclout\" without verification.\Use overwrite parameter.\n"
    		unless -t; #unless generated by a terminal?  is this really what we want?
            $self->{status} .= "override check\n";
            return undef if (!$self->{overwrite}); #was: return 1..which we've switched to 0 to be consistent with true/false
        } elsif (-e _) { #if the file already exists...
            unless ($self->{overwrite}) { die "Will not save <$url> as \"$lclout\".  Path exists.\n" } #overwrite bit added MP
        } else { # file doesn't yet exist on the system...do nothing to stop it from saving.
        }
    	$self->{status} .= "Saving to '$lclout'...\n";
    } else {
        if (defined $self->{local_dir_path}) {
            $self->{status} .= "output directory specified\n";
    		$lclout = File::Spec->catfile($self->{local_dir_path}, $lclout);
        }
    }
    return $lclout;
}

sub download {
    #call this with $self->download where $self is an object of class File::Download
    my $self = shift;
    my ($url) = @_;
    my $file; #$file is the local filename and should be $localDirPath."/".$localFileName
    $self->{user_agent} = LWP::UserAgent->new( agent => __PACKAGE__."::".__PACKAGE__->VERSION." ", keep_alive => 1, env_proxy => 1, ) if !$self->{user_agent};
    our $DL_innerSub = sub {
        $self->{status} = "Beginning download\n";
        my ($chunk,$res,$protocol) = @_;
        if (!defined $file || $self->{completion_status}==0) {#begin undefined $file section
            $self->{status} .= "file name not predefined\n";
            $file = $self->set_local_filename();
            if (!defined $file) { #we failed to set the filename...exit
                $self->{status} .= "failed to set filename...exiting...\n";
                return 0;
            }            
            #moved reorganized file opening code
            if ($self->{completion_status} == 0) {
                open(FILE, ">$file") || die "Can't open $file: $!\n";
                binmode FILE unless $self->{mode} eq 'a';
                $self->{start_t} = time;
                $self->{last_dur} = 0;
                $self->{size} = 0; #how much we've downloaded so far
                $self->{completion_status} = 1; #let the class object know that the download has begun
            }
            $self->{length} = $res->content_length();
            $self->{flength} = fbytes($self->{length}) if defined $self->{length};
            $self->{status} .= "exiting undefined file section\n";
        } # end undefined $file; 
        $self->{status} .= "file name = $file\n";	  
        print FILE $_[0] or die "Can't write to $file: $!\n"; #add the stream to the already open file handle
        if (!defined $self->{size}) { $self->{size} = 0 }
        $self->{size} += length($_[0]);
        if (defined $self->{length}) {
	      my $dur = time - $self->{start_t};
	      if (($dur >= $self->{last_dur}) || ($dur > 15)) {  # don't update too often
            $self->{last_dur} = $dur;
            my $perc = $self->{size} / $self->{length};
            my $speed;
            $speed = fbytes($self->{size}/$dur) . "/sec" if $dur > 3;
            my $secs_left = fduration($dur/$perc - $dur);
            $perc = int($perc*100);
            my $tstatus = "$perc% of ".$self->{flength};
            $tstatus .= " (at $speed, $secs_left remaining)" if $speed;
            $self->{status} .= $tstatus."\n";
            if ($perc > 100) {
                $self->{status} .= "Download has exceeded expected file size at ".$dur." seconds\n";
                $self->{completion_status} = 2;
            }
	      }
        } else {
	      $self->{status} .= "Finished? " . fbytes($self->{size}) . " received in ".time - $self->{start_t}." seconds\n";
          $self->{completion_status} = 2;
        }
      }; #end innersub
        
########## Back to main Download
    my $ua = $self->{user_agent};
 #   my $dl_req = HTTP::Request->new(GET => $url),
    my $res = $ua->request(HTTP::Request->new(GET => $url), $DL_innerSub);
    # from LWP user manual :
    # You are allowed to use a CODE reference as content in the request object passed in.
    # The content function should return the content when called. The content can be returned in chunks.
    # The content function will be invoked repeatedly until it return an empty string to signal that there is no more content.
    my $diecode;
    $self->{result} = $res; #for any debugging
    if (fileno(FILE)) { #check if file is assigned a file number
    	close(FILE) || die "Can't write to $file: $!\n";
#        my $bob = $self->{status};
    	my $dur = time - $self->{start_t}; #total duration
    	if ($dur) {
    	    my $speed = fbytes($self->{size}/$dur) . "/sec";
    	}
    	if (my $mtime = $res->last_modified) {
    	    utime time, $mtime, $file;
    	}
    	if ($res->header("X-Died") || !$res->is_success) {
    	    if (my $died = $res->header("X-Died")) {
                $self->{status} .= $died.".....\n";
    	    }
    	    if (-t) { #is this for piping?
                if ($self->{autodelete}) {
                    unlink($file);
                    $self->{status} .= "autodeleted.\n";
                } elsif ($self->{length} > $self->{size}) {
                    $self->{status} .= "Aborted. Truncated file kept: " . fbytes($self->{length} - $self->{size}) . " missing.\n";
                }
                $diecode=sprintf("res:%s\nstr:%s\ncontent:%s\ndec-cont:%s\nmess:%s\nstatus:%s\n", $res, $res->as_string, $res->content, $res->decoded_content, $res->message, $self->{status});
                return 0; # Houston, we have a problem?
    	    } else {
                $self->{status} .= "Transfer aborted, $file kept\n";
                $diecode=sprintf("res:%s\nstr:%s\ncontent:%s\ndec-cont:%s\nmess:%s\nstatus:%s\n", $res, $res->as_string, $res->content, $res->decoded_content, $res->message, $self->{status});
#                die $diecode;
    	    }
    	}
        $self->{status} .= "Success or partial file kept: ".$self->{size}."/".$self->{length};
#        $diecode=sprintf("res:%s\nstr:%s\ncontent:%s\ndec-cont:%s\nmess:%s\nstatus=success::%s\n", $res, $res->as_string, $res->content, $res->decoded_content, $res->message, $self->{status});
    	return 1; #good
    } else { #the file is already closed?
        if (!defined $self->{status}) {
            $self->{status} = "File already closed?\n";
        } else {
            if (!defined $self->{size}) {$self->{size} = -1}
            if (!defined $self->{length}) {$self->{length} = -1}
            $self->{status} .= "File already closed? ".$self->{size}."/".$self->{length}."\n";
        }
        $diecode=sprintf("res:%s\nstr:%s\ncontent:%s\ndec-cont:%s\nmess:%s\nstatus=filealreadycreated:%s\n", $res, $res->as_string, $res->content, $res->decoded_content, $res->message, $self->{status});
        return 0; #baaaaaad
    }
}

sub fbytes
{
    my $n = int(shift);
    if ($n >= 1024 * 1024) {
	return sprintf "%.3g MB", $n / (1024.0 * 1024);
    }
    elsif ($n >= 1024) {
	return sprintf "%.3g KB", $n / 1024.0;
    }
    else {
	return "$n bytes";
    }
}

sub fduration
{
    use integer;
    my $secs = int(shift);
    my $hours = $secs / (60*60);
    $secs -= $hours * 60*60;
    my $mins = $secs / 60;
    $secs %= 60;
    if ($hours) {
	return "$hours hours $mins minutes";
    }
    elsif ($mins >= 2) {
	return "$mins minutes";
    }
    else {
	$secs += $mins * 60;
	return "$secs seconds";
    }
}

1;
__END__

=head1 NAME

File::Download - Fetch large files from the web

=head1 DESCRIPTION

This Perl module is largely derived from the B<lwp-download> program 
that is installed by LWP or the libwww-perl networking package. This
module abstracts the functionality found in that perl script into a
module to provide a simpler more developer-friendly interface for 
downloading large files.

=head1 USAGE

=head2 METHODS

=over

=item B<download($url)>

This starts the download process by downloading the file located
at the specified URL. Return 1 if download was successful and
0 otherwise.

=item B<status()>

This returns a human readable status message about the download.
It can be used to determine if the download successed or not.

=item B<user_agent()>

Get or set the current user agent that will be used in 
conjunctions with downloads.

=cut

=head2 OPTIONS

Each of the following options are also accessors on the main
File::Download object.

=over

=item B<outfile>

Optional. The name of the file you wish to save the download to.

If you do NOT specific an outfile, then the system will attempt
to determine the destination file name based upon the requested
URL.

If you specify a DIRECTORY as an outfile, then the downloaded file
will be written to that directory with the file name being derived
from the URL requested.

If you specify a FILE as an outfile, then the downloaded file will
be saved with that name. You may use both a relative or absolute
path to the file you wish to save. If a file by that name already
exists you may need to specify the C<overwrite> option (see below).

=item B<overwrite>

Optional. Boolean value which controls whether or not a previously 
downloaded file with the same file name will be overwritten.
Default false.

=item B<mode>

Optional. Allowable values include "a" for ASCII and "b" for binary
transfer modes. Default is "b".

=item B<username>

Not implemented yet.

=item B<password>

Not implemented yet.

=cut

=head1 EXAMPLE

Fetch the newest and greatest perl version:

   my $dwn = File::Download->new({
     file => $argfile,
     overwrite => 1,
     mode => ($opt{a} ? 'a' : 'b'),
   });
   print "Downloading $url\n";
   print $dwn->download($url);
   print $dwn->status();

=head1 AUTHORS and CREDITS

Gisle Aas <gisle@aas.no> - original B<lwp-download> script
Byrne Reese <byrne@majordojo.com> - perl module wrapper
Matt Pagel <pagel@cs.wisc.edu> - update for perl > 5.6.0

=cut
