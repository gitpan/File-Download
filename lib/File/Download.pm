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
use Class::Accessor::Constructor 'antlers';	# Switching to moose-like 'antler' mode. Also need a "new" constructor.
has 'outfile' => (is => 'rw');				# name or directory to use on the local system
has 'overwrite' => (is => 'rw');				# overwrite file if it already exists locally (1).
has 'refresh' => (is => 'rw');				# update stale files
has 'last_mod_time' => (is => 'rw');		# initially set by either reading a config file or via $self->check_local_timestamp("filename")
has 'ETag' => (is => 'rw');					# initially set by a reading a config file and then sets the If-None-Match field; gets re-set by this method by the HTTP::Response ETag field
has 'user_agent' => (is => 'rw');			# allows us to pass in cookies
has 'username' => (is => 'rw');				# not supported
has 'password' => (is => 'rw');				# not supported
has 'autodelete' => (is => 'rw');			# probably tied to overwrite
has 'mode' => (is => 'rw');					# 'b' for binary, 'a' for ASCII
has 'result' => (is => 'rw');					# Provides access to the result of the 
has 'file' => (is => 'rw');					# Just so it doesn't complain when you call it in the style of the 1st version of File::Download
# has 'VERSION' => (is => 'ro');				# Don't need this - set via explicit definition. Otherwise cpan won't compile it right.
# has 'DEBUG' => (is => 'rw');				# Doesn't do diddlysquat

# I really don't want to expose the below, but perl complains if these are 'ro' and I try to set the values internally. Declaring with 'our' doesn't seem an option either.
# Suggestions for a better set of implementations would be appreciated. Package these into a single list tied together as an "our" variable?
has 'flength' => (is => 'rw'); 				# I would rather have this inaccessible and thus set to 'ro' (see above)
has 'size' => (is => 'rw');					# see above
has 'status' => (is => 'rw');					# see above
has 'length' => (is => 'rw');					# see above
has 'start_t' => (is => 'rw');				# see above
has 'last_dur' => (is => 'rw');				# see above
has 'local_file_name' => (is => 'rw');		# see above
has 'local_dir_path' => (is => 'rw');		# see above
has 'remote_url' => (is => 'rw');			# see above
has 'completion_status' => (is => 'rw');	# see above; 0 is not yet initiated; 1 when the filenames have been determined and we are ready to begin; 2 when done

use constant DEFAULTS => ( # used by the constructor
#	VERSION => '0.4_050601',
#	DEBUG => 0,
	overwrite => 1,
	refresh => 1,
	flength => 0,
	status => "not started\n",
	remote_url => "http://",
	username => 'not supported',
	password => 'not supported',
	start_t => 0,
	last_dur => 0,
	autodelete => 0,
	completion_status => 0,
	mode => 'b'
);

__PACKAGE__->mk_constructor;
$FILE::DOWNLOAD::VERSION = '0.4_050601' unless defined $FILE::DOWNLOAD::VERSION; #perl 5.6.1 version May, 2015 Matt Pagel
# __PACKAGE__->{DEBUG} = 0; # Of no use in current code state.
use LWP::UserAgent (); # Include, but require explicit reference to functions inside to use
use LWP::MediaTypes qw(guess_media_type media_suffix);
use URI ();
use HTTP::Date qw(str2time time2str);
use HTTP::Request ();
use HTTP::Response ();
use File::Spec ();
use Cwd qw(cwd getcwd);
use File::stat qw(stat);
# use Config::IniFiles ();

sub DESTROY { }

$SIG{INT} = sub { die "Interrupted\n"; };
$| = 1;	# autoflush

### note to self: consider checking the outfile/outdir for last modified time; then set HTTP If-Modified-Since header on the request


sub set_local_dir_get_fname { # checks local_dir_path parameter or sets it according to the outfile parameter; returns the filename portion
	my $self = shift;
	my $retval = '';
	my ($local_dirNfn, $local_fn, $vol, $dir);
	unless (defined $self->{local_dir_path}) {
		if (defined $self->{outfile}) {
			if (-d $self->{outfile}) {
				$self->{local_dir_path} = $self->{outfile};	# $retval = ''
			} else {
				$local_dirNfn = File::Spec->rel2abs($self->{outfile}); # if already an absolute path, it'll clean this up
				($vol, $dir, $local_fn) = File::Spec->splitpath($local_dirNfn);
				if (defined $self->{local_file_name} && $self->{local_file_name} ne '') { $local_fn = $self->{local_file_name} } # we've probably already been through this once, so trust what filename was assigned previously
				if ($local_fn eq '') { # outfile was a directory name...but based on the logic to this point, the directory doesn't exist
					$self->{local_dir_path} = $local_dirNfn;	# should we 'die' here? $retval = ''
				} else {
					if (-d $local_dirNfn) { # can this even happen? maybe if the outfile parameter was sufficiently screwy.
						$self->{local_dir_path} = $local_dirNfn; # $retval = ''
					} else {
						$self->{local_dir_path} = File::Spec->catpath($vol, $dir, ''); # or undef?
						$retval = $local_fn
					}
				}
			}
		} else { $self->{local_dir_path} = File::Spec->rel2abs(cwd()) } # output filename is also as-yet unknown
	} elsif (defined $self->{local_file_name} && $self->{local_file_name} ne '') { # we've probably been here before
		$retval = $self->{local_file_name}
	} else { # local_dir_path was set previously, but local_file_name wasn't set. We probably haven't yet started our HTTP::Request yet
		if (defined $self->{outfile}) {
#			$retval = $self->{outfile}; # this is probably a bit lazy - probably should strip away the directory name as-above. Need this value to be blank to properly process first time through set_local_filename
		} else {
			my $remURL = $self->{remote_url};
			($vol, $dir, $local_fn) = File::Spec->splitpath($remURL);
#			$retval = $local_fn; # Need this value to be blank to properly process first time through set_local_filename
		}
	}
	return $retval
}

sub set_local_filename	{ # call this with $self->set_local_filename(\$res) internally where $res is a Http::Response object
	my $self = shift;
	my $res_ref = shift;
	my $lclout;
	$lclout = $self->set_local_dir_get_fname();
#	unless (-d $self->{local_dir_path}) { die ("$self->{local_dir_path} from $self->{outfile} is not an existing direcory") };
	unless (defined $lclout && length($lclout)) { # block fixed from File::Download version 0.1-0.3 - outfile wasn't defined in the block to follow
		$self->{status} .= "output filename (outfile parameter) not defined or was a directory\n";
		$lclout = $$res_ref->filename; # look for header tag that defines the filename
		unless ($lclout) { # if the above fails we try to make something from the URL
			$self->{status} .= "file name not defined in header\n";
			my $req = $$res_ref->request;	# not always there
			my $rurl = $req ? $req->url : $self->{remote_url};
			$lclout = ($rurl->path_segments)[-1];
			if (!defined($lclout) || !length($lclout)) {
				$lclout = "index";
				my $suffix = media_suffix($$res_ref->content_type);
				$lclout .= ".$suffix" if $suffix;
			} elsif ($rurl->scheme eq 'ftp' || $lclout =~ /\.t[bg]z$/ || $lclout =~ /\.tar(\.(Z|gz|bz2?))?$/) { # do nothing else to the name; don't know why FTP is so special
			} else {
				$self->{status} .= "guessing media type\n";
				my $ct = guess_media_type($lclout);
				unless ($ct eq $$res_ref->content_type) { # need a better suffix for this type
					my $suffix = media_suffix($$res_ref->content_type);
					$lclout .= ".$suffix" if $suffix;
				}
			}
		}
	} # even if the filename was previously defined, we should probably do the checks to follow...unless the download has already started and connection is valid
	$self->{local_file_name} = $lclout unless ($$res_ref->is_error || $$res_ref->is_redirect);	# writeback
	$self->{status} .= "going to try to use name $lclout locally\n";
	if ($self->{completion_status} == 0) {
		# validate that we don't have a harmful local filename now.	The server might try to trick us into doing something bad.
		if ($lclout && !length($lclout) || $lclout =~ s/([^a-zA-Z0-9_\.\-\+\~])/sprintf "\\x%02x", ord($1)/ge) {
			die "Will not save <".$self->{remote_url}."> as \"$lclout\".\nPlease override file name using the 'outfile' parameter.\n";
		}
		if (defined $self->{local_dir_path}) {
			$self->{status} .= "output directory specified\n";
			$lclout = File::Spec->catfile($self->{local_dir_path}, $lclout); # the variable now has a full path; was previously just the filename portion
		} else { # we're good...the variable was just a filename to begin with.... we probably don't need to do anything here, but to be consistent, we'll set directory too
			$self->{local_dir_path} = File::Spec->rel2abs(cwd()); # we probably don't need to do this.
			$lclout = File::Spec->catfile($self->{local_dir_path}, $lclout); # the variable now has a full path; was previously just the filename portion
			$self->{status} .= "Filename approved. Augmented with current directory. Complete path set as $lclout\n";
		}
		# Check if the file is already present
		if (-l $lclout) {
			die "Will not save <".$self->{remote_url}."> to link \"$lclout\".\nPlease change filename.\n";
		} elsif (-f _) { # if it's a plain file...whatever that is
			die "Will not save <".$self->{remote_url}."> as \"$lclout\" without verification.\Use overwrite parameter.\n" unless -t; # unless generated by a terminal?	is this really what we want?
			$self->{status} .= "override check\n";
			return 0 if (!$self->{overwrite}); # was: return 1..which we've switched to 0 to be consistent with true/false; undef possible?
		} elsif (-e _) { # if the file already exists...
			unless ($self->{overwrite}) { die "Will not save <".$self->{remote_url}."> as \"$lclout\". Path exists.\n" } # overwrite flag added MP; further add update flag?
		} else { # file doesn't yet exist on the system...do nothing to stop it from saving.
		}
		if ($$res_ref->is_error || $$res_ref->is_redirect) {
			$self->{status} .= "should refuse to use $lclout due to error code ".$$res_ref->code
		} else {
			$self->{status} .= "Saving to '$lclout'...\n";
		}
	} else {
		if (defined $self->{local_dir_path}) {
			$self->{status} .= "output directory specified\n";
			$lclout = File::Spec->catfile($self->{local_dir_path}, $lclout);
		}
	}
	return $lclout;	# return the full path of the file to be saved locally
}

sub check_local_timestamp {
	my $self = shift;
	my $fn = shift;
	my $st;
	my $retval; #undef
	unless (defined $fn && $fn ne '') {
		if (defined $self->{outfile}) {
			$fn = $self->{outfile}; # this is probably a bit lazy - probably should strip away the directory name as-above.
		} else {
			my $remURL = $self->{remote_url};
			if (defined $remURL) {
				my ($vol, $dir, $local_fn) = File::Spec->splitpath($remURL);
				$fn = $local_fn; # Need this value to be blank to properly process first time through set_local_filename
			}
		}
	}
	if (defined $fn && $fn ne '') {
		if (-e $fn) {
			$st = stat($fn);
			$retval = time2str($st->mtime) #(stat($fn))[9] # 9=mtime = modify time
			# check timestamp of file (related: add 2 seconds or round to adjust for potential FAT32 timestamp granularity?)
		} elsif (-d $self->{local_dir_path}) {
			$st = stat($self->{local_dir_path}); #[9]
			$retval = time2str($st->mtime)
		} else {
			#set overwrite flag to true? Or do we truly not have enough info at this time to judge whether we want to overwrite/update?
			$retval = time2str(1) # set the mod time to be one second after epoch; the server's file will certainly be more recent than this
		}
	}
}

sub lintWorkAround {
	my $self = shift;
	my $freshcode = 304;
	my $LintErrorWorkAroundNumber = 500;
	my $grepTitle = "Rack::Lint::LintError";
	my $grepTxt = "Content-Length header found in $freshcode response";
	my ($helptxt, $retcode);
	if ($self->{refresh}) {
		if ($self->result->code == $LintErrorWorkAroundNumber) {
			if ((defined $self->result->header("Title")) && ($self->result->header("Title") =~ /$grepTitle/)) {
				if ($self->result->as_string() =~ /$grepTxt/) {
					$helptxt = "The server attempted to return a $freshcode response indicating that the current file version is up-to-date, but then caused itself to choke.\n";
					$helptxt .= "This is because Rack::Lint server-side inappropriately throws an error on the $freshcode responses by nginx and Unicorn, which are attempting to report the size of the matching file.\n";
					$self->result->code($freshcode); # Pretend this never happened :)
					$self->{completion_status} = 2;
					$retcode = 1; #1;
				} else {
					$helptxt = $self->result->as_string()."\nThere was an internal server error. Examine for a $freshcode string\n\n";
					$retcode = 0;
				}
			} else { # no title match
				$helptxt = $self->result->headers_as_string()."Lint or other $LintErrorWorkAroundNumber Error detected in the above; not $freshcode\n";
				$retcode = 0;
			}
		} elsif ($self->result->code == $freshcode) {
			$helptxt = "Fresh content detected ($freshcode)\n";
			$self->{completion_status} = 2;
			$retcode = 1; #1;
		} else { # no lint error
			$helptxt = $self->result->code." must not be $LintErrorWorkAroundNumber; Must not be $freshcode either\n";
			$retcode = 0;
		}
	} else {
		$helptxt = "Confusion ensues. We shouldn't have been looking at headers.\n";
		$retcode = 0;
	}
	$self->{status} .= $helptxt;
#	warn "\n".$helptxt;
	return $retcode
}

sub download { # call this with $self->download($url) where $self is an object of class File::Download and $url is the string of an URL/URI
	my $self = shift;
	($self->{remote_url}) = @_;
	my $error_made_fresh = 0;
	my $freshcode = 304;
	if (!$self->{completion_status}) {
		undef $self->{local_dir_path};	# don't trust the end-user
		undef $self->{local_file_name};	# don't trust the end-user
	}
#	my $fil = $self->set_local_dir_get_fname();
#	if ($fil ne '' && $self->{refresh}) {
#		if (defined $self->{last_mod_time} && $self->{last_mod_time}) { $local_timestamp = $self->{last_mod_time} }
#		else {$local_timestamp = time2str(1)} #$local_timestamp = $self->check_local_timestamp($fil)
#		if (defined $self->{ETag} && $self->{ETag}) {
			#code
#		}
#	}
	my $file; #new variable to ensure we call the whole filename builder.
#	$file is the local filename and should be $localDirPath."/".$localFileName
	$self->{user_agent} = LWP::UserAgent->new(agent => __PACKAGE__."::".__PACKAGE__->VERSION." ", keep_alive => 1, env_proxy => 1,) if !$self->{user_agent};
#	$self->{result} = $ua->request(HTTP::Request->new(GET => $url), &$DL_innerSub); # breaking this out seems to lose some of the variable definitions. Maybe would work with proper prototyping
	if ($self->{refresh}) {
		if (defined $self->{last_mod_time} && $self->{last_mod_time}) { $self->{user_agent}->default_header('If-Modified-Since' => $self->{last_mod_time}) }
		if (defined $self->{ETag} && $self->{ETag}) { $self->{user_agent}->default_header('If-None-Match' => $self->{ETag}) }
	}
	$self->{result} = $self->{user_agent}->request(HTTP::Request->new(GET => $self->{remote_url}), sub { 
		my ($chunk, $res, $protocol) = @_; # 'shift' first if inner sub?
		if (defined $self->{user_agent}->cookie_jar) {$self->{user_agent}->cookie_jar->extract_cookies($res)}
		$self->{status} = "Beginning download; len: ".length($chunk)."; ".$res." via $protocol\n";
		if (!defined $file) {# begin undefined $file section ... had || ($self->{completion_status}==0) here...
			$self->{status} .= "file name not predefined\n";
			$file = $self->set_local_filename(\$res);
			if (!defined $file) { #we failed to set the filename...exit
				$self->{status} .= "failed to set filename...exiting...\n";
				return 0;
			}				
			# reorganized file opening code
			if (($self->{completion_status} == 0) || (!fileno(FILE))) {
				open(FILE, ">$file") || die "Can't open $file: $!\n";
				binmode FILE unless $self->{mode} eq 'a';
				$self->{start_t} = time;
				$self->{last_dur} = 0;
				$self->{size} = 0; # how much we've downloaded so far
				$self->{completion_status} = 1; # let the class object know that the download has begun
			}	
			$self->{length} = $res->content_length();
			$self->{flength} = fbytes($self->{length}) if defined $self->{length};
			$self->{status} .= "exiting undefined file section\n";
		} # end undefined $file; 
		$self->{status} .= "file name = $file\n";		
		print FILE $_[0] or die "Can't write to $file: $!\n";	# add the stream (chunk?) to the already open file handle
		if (!defined $self->{size}) { $self->{size} = 0 }
		$self->{size} += length($_[0]);
		if (defined $self->{length}) {
			my $dur = time - $self->{start_t};
			if (($dur >= $self->{last_dur}) || ($dur > 15)) {	# don't update too often, but at least once every 15 seconds
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
	}); #end innersub
### Back to main Download method###

# From LWP user manual:
#	You are allowed to use a CODE reference as content in the request object passed in.
#	The content function should return the content when called. The content can be returned in chunks.
#	The content function will be invoked repeatedly until it return an empty string to signal that there is no more content.
	if (defined $self->{user_agent}->cookie_jar) { $self->{user_agent}->cookie_jar->extract_cookies($self->{result}) }
	my $diecode;	# consider writing this to status
	my $mtime;
	if ($self->{refresh}) {
		if ($self->result->code == $freshcode) {
			if (defined $self->{result}->header("ETag")) { $self->{ETag} = $self->{result}->header("ETag") }
			if (defined $self->{result}->header("Last-Modified")) { $self->{last_mod_time} = $self->{result}->header("Last-Modified") }
			elsif (defined $self->{result}->header("Date")) { $self->{last_mod_time} = $self->{result}->header("Date") }
			$self->{status} .= "File seems fresh\n"
		} elsif ($self->result->is_error) { # || $self->result->is_redirect) {
			$error_made_fresh = $self->lintWorkAround(); #do not set headers
			warn $self->{remote_url}." result. procedure: $error_made_fresh\tfinal error: ".$self->result->code."\n";
		}
	}
	if (fileno(FILE)) { # check if file is assigned a file number
		close(FILE) || die "Can't write to $file: $!\n";
		my $dur = time - $self->{start_t}; # total duration
		if ($dur) { my $speed = fbytes($self->{size}/$dur) . "/sec"; }
		if (defined $self->{result}->header("Last-Modified")) { $mtime = $self->{result}->header("Last-Modified") }
		elsif (defined $self->{result}->header("Date")) { $mtime = $self->{result}->header("Date") }
		if (defined $mtime && $mtime) { # set access time to current, set modified time to server's modified time; otherwise use start_t as the modified time?
			$self->{last_mod_time} = $mtime;
			$mtime = str2time($mtime);
			utime time, $mtime, $file;
			if (defined $self->{local_dir_path}) {	# do the same for the directory
				utime time, $mtime, $self->{local_dir_path}
			}
		}
		if ($self->{result}->header("X-Died") || !$self->{result}->is_success) {
			if (my $died = $self->{result}->header("X-Died")) { $self->{status} .= $died.".....\n"; }
#			if ($self->{refresh}) {
#				return $self->lintWorkAround();
#			}
			if (-t) { # is this for piping?
				if ($self->{autodelete}) {
					unlink($file);
					$self->{status} .= "autodeleted.\n";
				} elsif ($self->{length} > $self->{size}) {
					$self->{status} .= "Aborted. Truncated file kept: " . fbytes($self->{length} - $self->{size}) . " missing.\n";
				}
				$diecode=sprintf("res:%s\nstr:%s\ncontent:%s\ndec-cont:%s\nmess:%s\nstatus:%s\n", $self->{result}, $self->{result}->as_string, $self->{result}->content, $self->{result}->decoded_content, $self->{result}->message, $self->{status});
				return 0; # Houston, we have a problem?
			} else {
				$self->{status} .= "Transfer aborted, $file kept\n";
				$diecode=sprintf("res:%s\nstr:%s\ncontent:%s\ndec-cont:%s\nmess:%s\nstatus:%s\n", $self->{result}, $self->{result}->as_string, $self->{result}->content, $self->{result}->decoded_content, $self->{result}->message, $self->{status});
				return 0;
			}
		}
		if (defined $self->{result}->header("ETag")) { $self->{ETag} = $self->{result}->header("ETag") }
		$self->{status} .= "Success: ".$self->{size}."/".$self->{length};
		return 1; # good
	} else { # the file is already closed?
		if (!defined $self->{status}) {
			$self->{status} = "File already closed?\n";
		} else {
			if (!defined $self->{size}) {$self->{size} = -1}
			if (!defined $self->{length}) {$self->{length} = -1}
			$self->{status} .= "File already closed? Can't be opened because it is open somewhere else? 500+ error?".$self->{size}."/".$self->{length}."\n";
		}
		$diecode = sprintf("Str: %s\n=====\nCont: %s\n=====\nDec-Cont: %s\n=====\nRes-code: %u\n=====\nResHash: %s\n", $self->{result}->as_string, $self->{result}->content, $self->{result}->decoded_content, $self->{result}->code, $self->{result});
		if ($self->{refresh}) {
			if ($self->result->is_error) { # || $self->result->is_redirect) {
				warn $self->{remote_url}." result. procedure: ".$self->lintWorkAround()."(prev $error_made_fresh)\tfinal error: ".$self->result->code."\n";
			} elsif ($self->result->is_redirect) {
				warn $self->{remote_url}.". final code: ".$self->result->code
			}
		}
		$self->{status} = sprintf("%s%sRefresh: %u\tCode: %u\tError? %u\tRedirect? %u\n",$diecode,$self->{status},$self->{refresh}, $self->result->code, $self->result->is_error, $self->result->is_redirect);
#		$diecode=sprintf("res:%s\nstr:%s\ncontent:%s\ndec-cont:%s\nmess:%s\nstatus=filealreadycreated:%s\n", $self->{result}, $self->{result}->as_string, $self->{result}->content, $self->{result}->decoded_content, $self->{result}->message, $self->{status});
		return 0; # baaaaaad
	}
}

sub fbytes {
	my $n = int(shift);
	if ($n >= 1024 * 1024) {
		return sprintf "%.3g MB", $n / (1024.0 * 1024);
	} elsif ($n >= 1024) {
		return sprintf "%.3g KB", $n / 1024.0;
	} else {
		return "$n bytes";
	}
}

sub fduration {
	use integer;
	my $secs = int(shift);
	my $hours = $secs / (60*60);
	$secs -= $hours * 60*60;
	my $mins = $secs / 60;
	$secs %= 60;
	if ($hours) {
		return "$hours hours $mins minutes";
	} elsif ($mins >= 2) {
		return "$mins minutes";
	} else {
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
		outfile => $argfile,
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
