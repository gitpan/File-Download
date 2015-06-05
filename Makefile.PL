use strict;
use warnings;
use 5.006_001; use 5.6.1; #5.6.0 may work as well, but we may as well require a step up.
use ExtUtils::MakeMaker;
use Cwd qw(cwd getcwd);
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile (
	'NAME'			=> 'File::Download',
	'VERSION_FROM'	=> cwd().'/'.'lib/File/Download.pm',
	'ABSTRACT'		=> "A simple module for file downloading",
	'AUTHOR'			=> 'Byrne Reese <byrne@majordojo.com> and Matt Pagel <pagel@cs.wisc.edu>',
	'DISTNAME'		=> 'File-Download',
#	'LICENSE'		=> 'perl',
	'LIBS'			=> [''],	# e.g., '-lm' 
	'DEFINE'			=> '',	# e.g., '-DHAVE_SOMETHING' 
	'INC'				=> '',	# e.g., '-I/usr/include/other' 
#	'PM'	=> {'Spec.pm'	=> '$(INST_LIBDIR)/File/Spec.pm',
#				'OS2.pm'	=> '$(INST_LIBDIR)/File/Spec/OS2.pm',
#				'Win32.pm'	=> '$(INST_LIBDIR)/File/Spec/Win32.pm',
#				'VMS.pm'	=> '$(INST_LIBDIR)/File/Spec/VMS.pm',
#				'Unix.pm'	=> '$(INST_LIBDIR)/File/Spec/Unix.pm',
#				}
);
__END__
use inc::Module::Install;

name('File-Download');
abstract('A simple file download module');
author('Byrne Reese <byrne@majordojo.com> and Matt Pagel <pagel@cs.wisc.edu>');
version_from(cwd().'/'.'lib/File/Download.pm');
license('perl');
no_index(directory => 't');
sign(0);

include('ExtUtils::AutoInstall');

requires('LWP::UserAgent');
requires('LWP::MediaTypes');
requires('URI');
requires('HTTP::Date');
requires('HTTP::Request');
requires('HTTP::Response');
requires('Class::Accessor::Constructor');
requires('File::Spec');
requires('File::stat');
requires('integer');
requires('Cwd');
# requires('Config::IniFiles');

features(
	'Downloader' => [
		-default => 1,
		'LWP' => 1,
		'LWP::UserAgent' => 1,
		'LWP::MediaTypes' => 1,
		'URI' => 1,
		'HTTP::Date' => 1,
		'File::Spec' => 1,
		'File::stat' => 1,
		'Class::Accessor' => 1,
		'Class::Accessor::Constructor' => 1,
		'integer' => 1,
		'HTTP' => 1,
		'HTTP::Date' => 1,
		'HTTP::Request' => 1,
		'HTTP::Response' => 1,
		'Cwd' => 1,
#		'Config::IniFiles' => 1
	],
);

auto_include();
auto_install();

&WriteAll;
__END__
