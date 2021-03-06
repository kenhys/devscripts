#!/usr/bin/perl

# git-deborig -- try to produce Debian orig.tar using git-archive(1)

# Copyright (C) 2016-2018  Sean Whitton <spwhitton@spwhitton.name>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 NAME

git-deborig - try to produce Debian orig.tar using git-archive(1)

=head1 SYNOPSIS

B<git deborig> [B<--force>|B<-f>] [B<--just-print>] [B<--version=>I<VERSION>] [I<COMMITTISH>]

=head1 DESCRIPTION

B<git-deborig> tries to produce the orig.tar you need for your upload
by calling git-archive(1) on an existing git tag or branch head.  It
was written with the dgit-maint-merge(7) workflow in mind, but can be
used with other workflows.

B<git-deborig> will try several common tag names.  If this fails, or
if more than one of those common tags are present, you can specify the
tag or branch head to archive on the command line (I<COMMITTISH> above).

B<git-deborig> will override gitattributes(5) that would cause the
contents of the tarball generated by git-archive(1) not to be
identical with the commitish archived: the B<export-subst> and
B<export-ignore> attributes.

B<git-deborig> should be invoked from the root of the git repository,
which should contain I<debian/changelog>.

=head1 OPTIONS

=over 4

=item B<-f>|B<--force>

Overwrite any existing orig.tar in the parent directory.

=item B<--just-print>

Instead of actually invoking git-archive(1), output information about
how it would be invoked.  Ignores I<--force>.

Note that running the git-archive(1) invocation outputted with this
option may not produce the same output.  This is because
B<git-deborig> takes care to disables git attributes otherwise heeded
by git-archive(1), as detailed above.

=item B<--version=>I<VERSION>

Instead of reading the new upstream version from the first entry in
the Debian changelog, use I<VERSION>.

=back

=head1 SEE ALSO

git-archive(1), dgit-maint-merge(7)

=head1 AUTHOR

B<git-deborig> was written by Sean Whitton <spwhitton@spwhitton.name>.

=cut

use strict;
use warnings;

use Getopt::Long;
use Git::Wrapper;
use Dpkg::Changelog::Parse;
use Dpkg::IPC;
use Dpkg::Version;
use List::Compare;
use String::ShellQuote;
use Try::Tiny;

my $git = Git::Wrapper->new(".");

# Sanity check #1
try {
    $git->rev_parse({ git_dir => 1 });
}
catch {
    die "pwd doesn't look like a git repository ..\n";
};

# Sanity check #2
die "pwd doesn't look like a Debian source package ..\n"
  unless ( -e "debian/changelog" );

# Process command line args
my $overwrite = '';
my $user_version = '';
my $user_ref = '';
my $just_print = '';
GetOptions (
            'force|f' => \$overwrite,
            'just-print' => \$just_print,
            'version=s' => \$user_version
           ) || usage();
if ( scalar @ARGV == 1 ) {
    $user_ref = shift @ARGV;
} elsif ( scalar @ARGV >= 2) {
    usage();
}

# Extract source package name from d/changelog and either extract
# version too, or parse user-supplied version
my $version;
my $changelog = Dpkg::Changelog::Parse->changelog_parse({});
if ( $user_version ) {
    $version = Dpkg::Version->new($user_version);
} else {
    $version = $changelog->{Version};
}
my $source = $changelog->{Source};
my $upstream_version = $version->version();

# Sanity check #3
die "version number $version is not valid ..\n" unless $version->is_valid();

# Sanity check #3
# Only complain if the user didn't supply a version, because the user
# is not required to include a Debian revision when they pass
# --version
die "this looks like a native package .."
  if ( !$user_version && $version->is_native() );

# Default to gzip
my $compressor = "gzip -cn";
my $compression = "gz";
# Now check if we can use xz
if ( -e "debian/source/format" ) {
    open( my $format_fh, '<', "debian/source/format" )
      or die "couldn't open debian/source/format for reading";
    my $format = <$format_fh>;
    chomp($format) if defined $format;
    if ( $format eq "3.0 (quilt)" ) {
        $compressor = "xz -c";
        $compression = "xz";
    }
    close $format_fh;
}

my $orig = "../${source}_$upstream_version.orig.tar.$compression";
die "$orig already exists: not overwriting without --force\n"
  if ( -e $orig && ! $overwrite && ! $just_print );

if ( $user_ref ) {      # User told us the tag/branch to archive
    # We leave it to git-archive(1) to determine whether or not this
    # ref exists; this keeps us forward-compatible
    archive_ref_or_just_print($user_ref);
} else {    # User didn't specify a tag/branch to archive
    # Get available git tags
    my @all_tags = $git->tag();

    # convert according to DEP-14 rules
    my $git_upstream_version = $upstream_version;
    $git_upstream_version =~ y/:~/%_/;
    $git_upstream_version =~ s/\.(?=\.|$|lock$)/.#/g;

    # See which candidate version tags are present in the repo
    my @candidate_tags = ("$git_upstream_version",
                          "v$git_upstream_version",
                          "upstream/$git_upstream_version"
                         );
    my $lc = List::Compare->new(\@all_tags, \@candidate_tags);
    my @version_tags = $lc->get_intersection();

    # If there is only one candidate version tag, we're good to go.
    # Otherwise, let the user know they can tell us which one to use
    if ( scalar @version_tags > 1 ) {
        print "tags ", join(", ", @version_tags), " all exist in this repository\n";
        print "tell me which one you want to make an orig.tar from: git deborig TAG\n";
        exit 1;
    } elsif ( scalar @version_tags < 1 ) {
        print "couldn't find any of the following tags: ",
          join(", ", @candidate_tags), "\n";
        print "tell me a tag or branch head to make an orig.tar from: git deborig COMMITTISH\n";
        exit 1;
    } else {
        my $tag = shift @version_tags;
        archive_ref_or_just_print($tag);
    }
}

sub archive_ref_or_just_print {
    my $ref = shift;

    my $cmd = ['git', '-c', "tar.tar.${compression}.command=${compressor}",
               'archive', "--prefix=${source}-${upstream_version}/",
               '-o', $orig, $ref];
    if ( $just_print ) {
        print "$ref\n";
        print "$orig\n";
        my @cmd_mapped = map { shell_quote($_) } @$cmd;
        print "@cmd_mapped\n";
    } else {
        my ($info_attributes) =
          $git->rev_parse(qw|--git-path info/attributes|);
        my ($deborig_attributes) =
          $git->rev_parse(qw|--git-path info/attributes-deborig|);

        # For compatibility with dgit, we have to override any
        # export-subst and export-ignore git attributes that might be set
        rename $info_attributes, $deborig_attributes
          if ( -e $info_attributes );
        my $attributes_fh;
        unless ( open( $attributes_fh, '>', $info_attributes ) ) {
            rename $deborig_attributes, $info_attributes
              if ( -e $deborig_attributes );
            die "could not open $info_attributes for writing";
        }
        print $attributes_fh "* -export-subst\n";
        print $attributes_fh "* -export-ignore\n";
        close $attributes_fh;

        spawn(exec => $cmd,
              wait_child => 1,
              nocheck => 1);

        # Restore situation before we messed around with git attributes
        if ( -e $deborig_attributes ) {
            rename $deborig_attributes, $info_attributes;
        } else {
            unlink $info_attributes;
        }
    }
}

sub usage {
    die "usage: git deborig [--force|-f] [--just-print] [--version=VERSION] [COMMITTISH]\n";
}
