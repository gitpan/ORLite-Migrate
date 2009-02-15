package ORLite::Migrate;

# See POD at end of file for documentation

use 5.006;
use strict;
use Carp         ();
use Params::Util qw{ _STRING _CLASS _HASH };
use DBI          ();
use ORLite       ();

use vars qw{$VERSION @ISA};
BEGIN {
	$VERSION = '0.02';
	@ISA     = 'ORLite';
}

sub import {
	my $class = ref $_[0] || $_[0];

	# Check for debug mode
	my $DEBUG = 0;
	if ( defined _STRING($_[-1]) and $_[-1] eq '-DEBUG' ) {
		$DEBUG = 1;
		pop @_;
	}

	# Check params and apply defaults
	my %params;
	if ( defined _STRING($_[1]) ) {
		# Migrate needs at least two params
		Carp::croak("ORLite::Migrate must be invoked in HASH form");
	} elsif ( _HASH($_[1]) ) {
		%params = %{ $_[1] };
	} else {
		Carp::croak("Missing, empty or invalid params HASH");
	}
	$params{create} = $params{create} ? 1 : 0;
	unless (
		defined _STRING($params{file})
		and (
			$params{create}
			or
			-f $params{file}
		)
	) {
		Carp::croak("Missing or invalid file param");
	}
	unless ( defined $params{readonly} ) {
		$params{readonly} = $params{create} ? 0 : ! -w $params{file};
	}
	unless ( defined $params{tables} ) {
		$params{tables} = 1;
	}
	unless ( defined $params{package} ) {
		$params{package} = scalar caller;
	}
	unless ( _CLASS($params{package}) ) {
		Carp::croak("Missing or invalid package class");
	}
	unless ( $params{timeline} and -d $params{timeline} and -r $params{timeline} ) {
		Carp::croak("Missing or invalid timeline directory");
	}

	# We don't support readonly databases
	if ( $params{readonly} ) {
		Carp::croak("ORLite::Migrate does not support readonly databases");
	}

	# Get the schema version
	my $file     = File::Spec->rel2abs($params{file});
	my $created  = ! -f $params{file};
	if ( $created ) {
		# Create the parent directory
		my $dir = File::Basename::dirname($file);
		unless ( -d $dir ) {
			File::Path::mkpath( $dir, { verbose => 0 } );
		}
	}
	my $dsn      = "dbi:SQLite:$file";
	my $dbh      = DBI->connect($dsn);
	my $version  = $dbh->selectrow_arrayref('pragma user_version')->[0];
	$dbh->disconnect;

	# Build the migration plan
	my $timeline = File::Spec->rel2abs($params{timeline});
	my @plan = plan( $params{timeline}, $version );

	# Execute the migration plan
	if ( @plan ) {
		# Does the migration plan reach the required destination
		my $destination = $version + scalar(@plan);
		if ( exists $params{user_version} and $destination != $params{user_version} ) {
			die "Schema migration destination user_version mismatch (got $destination, wanted $params{user_version})";
		}

		# Load the modules needed for the migration
		require Probe::Perl;
		require File::pushd;
		require IPC::Run3;

		# Execute each script
		my $perl  = Probe::Perl->find_perl_interpreter;
		my $pushd = File::pushd::pushd($timeline);
		foreach my $patch ( @plan ) {
			my $stdin = "$file\n";
			if ( $DEBUG ) {
				print STDERR "Applying schema patch $patch...\n";
			}
			my $ok    = IPC::Run3::run3( [ $perl, $patch ], \$stdin, \undef, $DEBUG ? undef : \undef );
			unless ( $ok ) {
				Carp::croak("Migration patch $patch failed, database in unknown state");
			}
		}

		# Migration complete, set user_version to new state
		$dbh = DBI->connect($dsn);
		$dbh->do("pragma user_version = $destination");
		$dbh->disconnect;
	}

	# Hand off to the regular constructor
	return $class->SUPER::import( \%params, $DEBUG ? '-DEBUG' : () );
}





#####################################################################
# Simple Methods

sub patches {
	my $dir = shift;

	# Find all files in a directory
	local *DIR;
	opendir( DIR, $dir )       or die "opendir: $!";
	my @files = readdir( DIR ) or die "readdir: $!";
	closedir( DIR )            or die "closedir: $!";

	# Filter to get the patch set
	my @patches = ();
	foreach ( @files ) {
		next unless /^migrate-(\d+)\.pl$/;
		$patches["$1"] = $_;
	}

	return @patches;
}

sub plan {
	my $directory = shift;
	my $version   = shift;

	# Find the list of patches
	my @patches = patches( $directory );

	# Assemble the plan by integer stepping forwards
	# until we run out of timeline hits.
	my @plan = ();
	while ( $patches[++$version] ) {
		push @plan, $patches[$version];
	}

	return @plan;
}

1;

__END__

=pod

=head1 NAME

ORLite::Migrate - Extremely light weight SQLite-specific schema migration

=head1 SYNOPSIS

  # Build your ORM class using a patch timeline
  # stored in the shared files directory.
  use ORLite::Migrate {
      create       => 1,
      file         => 'sqlite.db',
      timeline     => File::Spec->catdir(
          File::ShareDir::module_dir('My::Module'), 'patches',
      ),
      user_version => 8,
  };

  # migrate-1.pl - A trivial schema patch
  #!/usr/bin/perl
  
  use strict;
  use DBI ();
  
  # Locate the SQLite database
  my $file = <STDIN>;
  chomp($file);
  unless ( -f $file and -w $file ) {
      die "SQLite file $file does not exist";
  }
  
  # Connect to the SQLite database
  my $dbh = DBI->connect("dbi:SQLite(RaiseError=>1):$file");
  unless ( $dbh ) {
    die "Failed to connect to $file";
  }
  
  $dbh->do( <<'END_SQL' );
  create table foo (
      id integer not null primary key,
      name varchar(32) not null
  )
  END_SQL

=head1 DESCRIPTION

B<THIS CODE IS EXPERIMENTAL AND SUBJECT TO CHANGE WITHOUT NOTICE>

B<YOU HAVE BEEN WARNED!>

L<SQLite> is a light weight single file SQL database that provides an
excellent platform for embedded storage of structured data.

L<ORLite> is a light weight single class Object-Relational Mapper (ORM)
system specifically designed for (and limited to only) work with SQLite.

L<ORLite::Migrate> is a light weight single class Database Schema
Migration enhancement for L<ORLite>.

It provides a simple implementation of schema versioning within the
SQLite database using the built-in C<user_version> pragma (which is
set to zero by default).

When setting up the ORM class, an additional C<timeline> parameter is
provided, which should point to a directory containing standalone
migration scripts.

These patch scripts are named in the form F<migrate-$version.pl>, where
C<$version> is the schema version to migrate to. A typical timeline directory
will look something like the following.

  migrate-01.pl
  migrate-02.pl
  migrate-03.pl
  migrate-04.pl
  migrate-05.pl
  migrate-06.pl
  migrate-07.pl
  migrate-08.pl
  migrate-09.pl
  migrate-10.pl

L<ORLite::Migrate> formulates a migration plan, it will start with the
current database C<user_version>, and then step forwards looking for a
migration script that has the version C<user_version + 1>.

It will continue stepping forwards until it runs out of patches to
execute.

If L<ORLite::Migrate> is also invoked with a C<user_version> param 
(to ensure the schema matches the code correctly) the plan will be
checked in advance to ensure that the migration will end at the value
specified by the C<user_version> param.

Because the migration plan can be calculated from any arbitrary starting
version, it is possible for any user of an older application version to
install the most current version of an application and be ugraded safely.

The recommended location to store the migration timeline is a shared files
directory, locatable using one of the functions from L<File::ShareDir>.

=head1 SUPPORT

Bugs should be reported via the CPAN bug tracker at

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=ORLite-Migrate>

For other issues, contact the author.

=head1 AUTHOR

Adam Kennedy E<lt>adamk@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2009 Adam Kennedy.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut
