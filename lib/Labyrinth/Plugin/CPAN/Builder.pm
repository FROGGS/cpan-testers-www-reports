package Labyrinth::Plugin::CPAN::Builder;

use strict;
use warnings;

use vars qw($VERSION);
$VERSION = '1.00';

=head1 NAME

CPAN::Builder - Plugin to build the static files that drive the dynamic site.

=cut

#----------------------------------------------------------------------------
# Libraries

use base qw(Labyrinth::Plugin::Base);

use Labyrinth::Audit;
use Labyrinth::DTUtils;
use Labyrinth::MLUtils;
use Labyrinth::Mailer;
use Labyrinth::Session;
use Labyrinth::Support;
use Labyrinth::Variables;
use Labyrinth::Writer;

use Labyrinth::Plugin::CPAN;
use Labyrinth::Plugin::Articles::Site;

use Clone   qw(clone);
use Cwd;
use File::Slurp;
use File::Path;
use JSON::XS;
#use Sort::Versions;
use Time::Local;
use XML::RSS;
#use YAML::XS;
use version;

#use Devel::Size qw(total_size);

#----------------------------------------------------------------------------
# Variables

my $RECENT  = 200;

#----------------------------------------------------------------------------
# Public Interface Functions

=head1 METHODS

=head2 Public Interface Methods

=over 4

=item BasicPages

Regenerates all site pages.

=item Process

Simple control process.

=item IndexPages

Rebuilds the index pages for each author and distribution letter directory.

=item AuthorPages

Rebuilds a named author page.

=item DistroPages

Rebuilds a named distribution page.

=item StatsPages

Rebuilds the stats pages for pass matrix.

=item RecentPage

Regenerates the recent page, and associated files.

=back

=cut

sub BasePages {
    my $cache = sprintf "%s/static", $settings{webdir};
    mkpath($cache);
    $tvars{cache}   = $cache;
    $tvars{static}  = 1;

    $tvars{content} = "content/welcome.html";
    Transform( 'cpan/layout-static.html', \%tvars, 'index.html' );

    my $site = Labyrinth::Plugin::Articles::Site->new();
    $tvars{content} = "articles/arts-item.html";
    for my $page (qw(help about)) {
        $cgiparams{'name'} = $page;
        $site->Item();
        Transform( 'cpan/layout-static.html', \%tvars, "page/$page.html" );
    }
}

sub Process {
    my ($self,$progress) = @_;

    my $cpan = Labyrinth::Plugin::CPAN->new();
    $cpan->Configure();

    my $olderhit = 0;
    my $quickhit = 1;
    while(1) {
        my $cnt = IndexPages($cpan,$dbi,$progress);
        
        # shouldn't really hard code these :)
        my ($query,$loop,$limit) = ('GetRequests',20,5);
        ($query,$loop,$limit) = ('GetOlderRequests',20,5)   if($quickhit == 1);
        ($query,$loop,$limit) = ('GetSmallRequests',2,10)   if($quickhit == 3);
        ($query,$loop,$limit) = ('GetLargeRequests',2,25)   if($quickhit == 5); # typically these are long running author searches

        my %names;
        for(1..$loop) {
            my @rows = $dbi->GetQuery('hash',$query,{limit=>$limit});
            last    unless(@rows);

            for my $row (@rows) {
                next    unless(defined $row->{type});
                next    if($names{$row->{type}} && $names{$row->{type}}{$row->{name}});
                if(defined $progress) {
                    $progress->( ".. processing $row->{type} $row->{name} => $row->{count} $row->{total}" );
                }
                if($row->{type} eq 'author')    { AuthorPages($cpan,$dbi,$row->{name},$progress) }
                else                            { DistroPages($cpan,$dbi,$row->{name},$progress) }

                $names{$row->{type}}{$row->{name}} = 1; # prevent repeating the same update too quickly.
                $cnt++;
            }
        }

        my $req = _request_count($dbi);
        $progress->( "Processed $cnt pages, $req requests remaining." ) if(defined $progress);
        sleep(300)   if($cnt == 0 || $req == 0);

        my $age = _request_oldest($dbi);

        $quickhit = 
            $age > $settings{agelimit1}                     # requests older than x days take priority
                ? 1    
                : $req < $settings{buildlevel1}             # low amount of requests 
                    ? 1 
                    : $req < $settings{buildlevel2}         # medium level of requests
                        ? ++$quickhit % 2
                        : $req < $settings{buildlevel3}     # high level of requests
                            ? ++$quickhit % 4
                            : $age > $settings{agelimit2}   # older than x days
                                ? 1
                                : ++$quickhit % 6;          # very high level of requests
    }
}

sub IndexPages {
    my ($cpan,$dbi,$progress) = @_;

    my @index = $dbi->GetQuery('hash','GetIndexRequests');
    for my $index (@index) {
        my ($type,@list);

        $progress->( ".. processing $index->{type} $index->{name}" )     if(defined $progress);

        if($index->{type} eq 'ixauth') {
            my @rows = $dbi->GetQuery('hash','GetAuthors',"$index->{name}%");
            @list = map {$_->{author}} @rows;
            $type = 'author';
        } else {
            my @rows = $dbi->GetQuery('hash','GetDistros',"$index->{name}%");
            @list = map {$_->{dist}} @rows;
            $type = 'distro';
        }

        my $cache = sprintf "%s/static/%s/%s", $settings{webdir}, $type, substr($index->{name},0,1);
        mkpath($cache);

        $tvars{letter}  = $index->{name};
        $tvars{cache}   = $cache;
        $tvars{content} = "cpan/$type-list.html";
        $tvars{list}    = \@list if(@list);
        Transform( 'cpan/layout-static.html', \%tvars, 'index.html' );

        if($type eq 'distro') {
            $cache = sprintf "%s/stats/%s/%s", $settings{webdir}, $type, substr($index->{name},0,1);
            mkpath($cache);

            my $destfile = "$cache/index.html";
            #$progress->( ".. processing $index->{type} $index->{name} - $destfile" )     if(defined $progress);
            $tvars{content} = 'cpan/stats-distro-index.html';
            $tvars{cache}   = $cache;
            Transform( 'cpan/layout-stats-static.html', \%tvars, 'index.html' );
        }

        # remove requests
        $dbi->DoQuery('DeletePageRequests',$index->{type},$index->{name});
    }

    return scalar(@index);
}

# - build author pages
# - update summary
# - remove page request entries

sub AuthorPages {
    my ($cpan,$dbi,$name,$progress) = @_;
    return  unless(defined $name);

    my %vars = %{ clone (\%tvars) };
#LogDebug("AuthorPages: before tvars=".total_size(\%tvars)." bytes");

    my @valid = $dbi->GetQuery('hash','FindAuthor',$name);
    if(@valid) {
        my @dists = $dbi->GetQuery('hash','GetAuthorDists',$name);
        if(@dists) {
            my %dists = map {$_->{dist} => $_->{version}} @dists;
            my $cache = sprintf "%s/static/author/%s", $settings{webdir}, substr($name,0,1);
            mkpath($cache);

            my (@reports,%reports,%summary);
            my $destfile = "$cache/$name.json";
            my $fromid   = '';
            my $lastid   = 0;

            # if we have a summary, process all reports to the last update from the JSON cache

            my @summary = $dbi->GetQuery('hash','GetAuthorSummary',$name);
            $lastid = $summary[0]->{lastid} if(@summary);

            if(-f $destfile && $lastid) {
                my $data  = read_file($destfile);
                my $store = decode_json($data);

                for my $row (@$store) {
                    next    if($lastid < $row->{id});
                    next    if($dists{$row->{dist}} ne $row->{version});    # ensure this is the latest dist version

                    unshift @{$reports{$row->{dist}}}, $row;
                    $summary{$row->{dist}}->{ $row->{status} }++;
                    $summary{$row->{dist}}->{ 'ALL' }++;
                    push @reports, $row;
                }

                $fromid = " AND id > $lastid "  if($lastid); 
            }

            # process all the reports from the last ID used

            my $next;
            if(scalar(@dists) > 300) {
                # a fairly constant 83-93 seconds regardless of volume
                $next  = $dbi->Iterator('hash','GetAuthorDistReports',{fromid=>$fromid},$name);
            } else {
                # 3-73 secs for dists of 1-100
                my $lookup = 'AND ( ' . join(' OR ',map {"(dist = '$_->{dist}' AND version = '$_->{version}')"} @dists) . ' )';
                $next  = $dbi->Iterator('hash','GetAuthorDistReports3',{lookup=>$lookup,fromid=>$fromid});
            }

            while(my $row = $next->()) {
                $row->{perl} = "5.004_05" if $row->{perl} eq "5.4.4"; # RT 15162
                $row->{perl} =~ s/patch.*/patch blead/  if $row->{perl} =~ /patch.*blead/;
                my ($osname) = $cpan->OSName($row->{osname});

                $row->{status}       = uc $row->{state};
                $row->{ostext}       = $osname;
                $row->{distribution} = $row->{dist};
                $row->{distversion}  = $row->{dist} . '-' . $row->{version};
                $row->{csspatch}     = $row->{perl} =~ /\b(RC\d+|patch)\b/ ? 'pat' : 'unp';
                $row->{cssperl}      = $row->{perl} =~ /^5.(7|9|[1-9][13579])/ ? 'dev' : 'rel';

                push @{$reports{$row->{dist}}}, $row;
                $summary{$row->{dist}}->{ $row->{status} }++;
                $summary{$row->{dist}}->{ 'ALL' }++;
                $lastid = $row->{id}    if($lastid < $row->{id});
                unshift @reports, $row;
            }

            for my $dist (@dists) {
                $dist->{letter}     = substr($dist->{dist},0,1);
                $dist->{reports}    = 1 if($reports{$dist->{dist}});
                $dist->{summary}    = $summary{$dist->{dist}};
                $dist->{cssrelease} = $dist->{version} =~ /_/ ? 'rel' : 'off';
                $dist->{csscurrent} = $dist->{type} eq 'backpan' ? 'back' : 'cpan';
            }

            $vars{builder}{author}          = $name;
            $vars{builder}{letter}          = substr($name,0,1);
            $vars{builder}{title}           = 'Reports for distributions by ' . $name;
            $vars{builder}{distributions}   = \@dists   if(@dists);
            $vars{builder}{perlvers}        = $cpan->mklist_perls;
            $vars{builder}{osnames}         = $cpan->osnames;
            $vars{builder}{processed}       = time;

            # insert summary details
            {
                my $dataset = encode_json($vars{builder});
                if(@summary)    { $dbi->DoQuery('UpdateAuthorSummary',$lastid,$dataset,$name); }
                else            { $dbi->DoQuery('InsertAuthorSummary',$lastid,$dataset,$name); }
            }

            # we have to do this here as we don't want all the reports in 
            # the encoded summary, just whether we have reports or not
            for my $dist (@dists) {
                $dist->{reports}    = $reports{$dist->{dist}};
            }

            $vars{cache}           = $cache;
            $vars{content}         = 'cpan/author-reports-static.html';
            $vars{processed}       = formatDate(8);

            # build other static pages
            $destfile = "$name.html";
            Transform( 'cpan/layout-static.html', \%vars, $destfile );

            $destfile = "$name.js";
            Transform( 'cpan/author.js', \%vars, $destfile );

            $destfile = "$cache/$name.json";
            overwrite_file( $destfile, _make_json( \@reports ) );
        }
    }

#LogDebug("AuthorPages: after  tvars=".total_size(\%tvars)." bytes");

    # remove requests
    $dbi->DoQuery('DeletePageRequests','author',$name);
}

# - build distro pages
# - update summary
# - remove page request entries

sub DistroPages {
    my ($cpan,$dbi,$name,$progress) = @_;
    return  unless(defined $name);

    my %vars = %{ clone (\%tvars) };

#LogDebug("DistroPages: before tvars=".total_size(\%tvars)." bytes");

    my $exceptions = $cpan->exceptions;
    my $symlinks   = $cpan->symlinks;
    my $merged     = $cpan->merged;

    my @delete = ($name);
    if($name =~ /^[A-Za-z0-9][A-Za-z0-9\-_+]*$/
                || ($exceptions && $name =~ /$exceptions/)) {

        # Some distributions are known by multiple names. Rather than create
        # pages for each one, we try and merge them together into one.

        my $dist;
        if($symlinks->{$name}) {
            $name = $symlinks->{$name};
            $dist = join("','", @{$merged->{$name}});
            @delete = @{$merged->{$name}};
        } elsif($merged->{$name}) {
            $dist = join("','", @{$merged->{$name}});
            @delete = @{$merged->{$name}};
        } else {
            $dist = $name;
            @delete = ($name);
        }

        my @valid = $dbi->GetQuery('hash','FindDistro',{dist=>$dist});
        if(@valid) {
            my $fromid = '';
            my $lastid = 0;
            my (@reports,%authors,%version,$summary,$byversion);

            # determine max dist/version for each pause id
            for(@valid) {
                $authors{$_->{author}}  = $_->{version};
                $version{$_->{version}} = { author => $_->{author}, new => 0, type => $_->{type}};
            }
            my %reports = map {$authors{$_} => []} keys %authors;

            # if we have a summary, process all reports to the last update from the JSON cache

            my @summary = $dbi->GetQuery('hash','GetDistroSummary',$name);
            $lastid = $summary[0]->{lastid} if(@summary);

             my $cache = sprintf "%s/static/distro/%s", $settings{webdir}, substr($name,0,1);
             my $destfile = "$cache/$name.json";
             mkpath($cache);
 
             # load JSON data if available
            if(-f $destfile && $lastid) {
                my $json = read_file($destfile);
                my $data = decode_json($json);
                for my $row (@$data) {
                    next    if($lastid < $row->{id});
                    push @reports, $row;

                    $summary->{ $row->{version} }->{ $row->{status} }++;
                    $summary->{ $row->{version} }->{ 'ALL' }++;
                    unshift @{ $byversion->{ $row->{version} } }, $row;

                    # record reports from max versions
                    unshift @{ $reports{$row->{version}} }, $row    if(defined $reports{$row->{version}});
                }

                $fromid = " AND id > $lastid "; 
            }

            my @rows = $dbi->GetQuery('hash','GetDistroReports',{fromid => $fromid, dist => $dist});
            for my $row (@rows) {
                $row->{perl} = "5.004_05"               if $row->{perl} eq "5.4.4"; # RT 15162
                $row->{perl} =~ s/patch.*/patch blead/  if $row->{perl} =~ /patch.*blead/;
                my ($osname) = $cpan->OSName($row->{osname});

                $row->{distribution} = $name;
                $row->{status}       = uc $row->{state};
                $row->{ostext}       = $osname;
                $row->{osvers}       = $row->{osvers};
                $row->{distversion}  = $name . '-' . $row->{version};
                $row->{csspatch}     = $row->{perl} =~ /\b(RC\d+|patch)\b/ ? 'pat' : 'unp';
                $row->{cssperl}      = $row->{perl} =~ /^5.(7|9|[1-9][13579])/ ? 'dev' : 'rel';
                $lastid = $row->{id}    if($lastid < $row->{id});
                unshift @reports, $row;

                $summary->{ $row->{version} }->{ $row->{status} }++;
                $summary->{ $row->{version} }->{ 'ALL' }++;
                push @{ $byversion->{ $row->{version} } }, $row;

                # record reports from max versions
                unshift @{ $reports{$row->{version}} }, $row    if($reports{$row->{version}});
                $version{$row->{version}}->{new} = 1;

            }

            for my $version ( keys %$byversion ) {
                my @list = @{ $byversion->{$version} };
                $byversion->{$version} = [ sort { $b->{id} <=> $a->{id} } @list ];
            }

            # ensure we cover all known versions
            @rows = $dbi->GetQuery('array','GetDistVersions',{dist=>$dist});
            my @versions = map{$_->[0]} @rows;
            my %versions = map {my $v = $_; $v =~ s/[^\w\.\-]/X/g; $_ => $v} @versions;

            my %release;
            for my $version ( keys %versions ) {
                $release{$version}->{csscurrent} = $version{$version}->{type} eq 'backpan' ? 'back' : 'cpan';
                $release{$version}->{cssrelease} = $version =~ /_/ ? 'dev' : 'off';
            }

            my ($stats,$oses);
            @rows = $dbi->GetQuery('hash','GetDistrosPass',{dist=>$dist});
            for(@rows) {
                my ($osname,$code) = $cpan->OSName($_->{osname});
                $stats->{$_->{perl}}{$code}{count} = $_->{count};
                $oses->{$code} = $osname;
            }

            # distribution PASS stats
            my @stats = $dbi->GetQuery('hash','GetStatsPass',{dist=>$dist});
            for(@stats) {
                my ($osname,$code) = $cpan->OSName($_->{osname});
                $stats->{$_->{perl}}{$code}{version} = $_->{version}
                    if(!$stats->{$_->{perl}}->{$code} || _versioncmp($_->{version},$stats->{$_->{perl}}->{$code}{version}));
            }

            my @stats_oses = sort keys %$oses;
            my @stats_perl = sort {_versioncmp($b,$a)} keys %$stats;
            my @stats_poff = grep {!/patch/} sort {_versioncmp($b,$a)} keys %$stats;

            $vars{title} = 'Reports for distribution ' . $name;

            $vars{builder}{distribution}    = $name;
            $vars{builder}{letter}          = substr($name,0,1);
            $vars{builder}{stats_code}      = $oses;
            $vars{builder}{stats_oses}      = \@stats_oses;
            $vars{builder}{stats_perl}      = \@stats_perl;
            $vars{builder}{stats_poff}      = \@stats_poff;
            $vars{builder}{stats}           = $stats;
            $vars{builder}{title}           = $vars{title};
            $vars{builder}{perlvers}        = $cpan->mklist_perls;
            $vars{builder}{osnames}         = $cpan->osnames;
            $vars{builder}{processed}       = time;

            # insert summary details
            {
                my $dataset = encode_json($vars{builder});
                if(@summary)    { $dbi->DoQuery('UpdateDistroSummary',$lastid,$dataset,$name); }
                else            { $dbi->DoQuery('InsertDistroSummary',$lastid,$dataset,$name); }
            }

            $vars{versions}        = \@versions;
            $vars{versions_tag}    = \%versions;
            $vars{summary}         = $summary;
            $vars{release}         = \%release;
            $vars{byversion}       = $byversion;
            $vars{cache}           = $cache;
            $vars{processed}       = formatDate(8);

            # build other static pages
            $destfile = "$name.html";
            $vars{content} = 'cpan/distro-reports-static.html';
            Transform( 'cpan/layout-static.html', \%vars, $destfile );

            $destfile = "$name.js";
            Transform( 'cpan/distro.js', \%vars, $destfile );

            $destfile = "$cache/$name.json";
            overwrite_file( $destfile, _make_json( \@reports ) );

            $cache = sprintf "%s/stats/distro/%s", $settings{webdir}, substr($name,0,1);
            mkpath($cache);
            $vars{cache} = $cache;

            $destfile = "$name.html";
            $vars{content} = 'cpan/stats-distro-static.html';
            Transform( 'cpan/layout-stats-static.html', \%vars, $destfile );

            # generate symbolic links where necessary
            if($merged->{$name}) {
                my $cwd = getcwd;
                chdir("$settings{webdir}/static/distro");
                for my $dist (@{$merged->{$name}}) {
                    next    if($dist eq $name);
                    for my $ext (qw(html json js)) {
                        my $source = substr($name,0,1) . "/$name.$ext" ;
                        my $target = substr($dist,0,1) . "/$dist.$ext" ;
                        next    if(!-f $source || -f $target);

                        eval {symlink($source,$target) ; 1};
                    }
                }
                chdir($cwd);
            }
        }
    }

#LogDebug("DistroPages: after tvars=".total_size(\%tvars)." bytes");

    # remove requests
    $dbi->DoQuery('DeletePageRequests','distro',$_) for(@delete);
}

sub StatsPages {
    my $cpan = Labyrinth::Plugin::CPAN->new();
    $cpan->Configure();

    my $cache = sprintf "%s/stats", $settings{webdir};
    mkpath($cache);

    #print STDERR "StatsPages: cache=$cache\n";

    my (%data,%perldata,%perls,%all_osnames,%dists,%perlos,%lookup);

    no warnings( 'uninitialized', 'numeric' );

    my $next = $dbi->Iterator('hash','GetStats');

    # build data structures
    while ( my $row = $next->() ) {
        #next if not $row->{perl};
        #next if $row->{perl} =~ / /;
        #next if $row->{perl} =~ /^5\.(7|9|11)/; # ignore dev versions
        #next if $row->{version} =~ /[^\d.]/;

        $row->{perl} = "5.004_05" if $row->{perl} eq "5.4.4"; # RT 15162

        my ($osname,$oscode) = $cpan->OSName($row->{osname});
        $row->{osname} = $oscode;
        $lookup{$oscode} = $osname;

        $perldata{$row->{perl}}{$row->{dist}} = $row->{version}             if $perldata{$row->{perl}}{$row->{dist}} < $row->{version};
        $data{$row->{dist}}{$row->{perl}}{$row->{osname}} = $row->{version} if $data{$row->{dist}}{$row->{perl}}{$row->{osname}} < $row->{version};
        $perls{$row->{perl}}{reports}++;
        $perls{$row->{perl}}{distros}{$row->{dist}}++;
        $perlos{$row->{perl}}{$row->{osname}}++;
        $all_osnames{$row->{osname}}++;
    }

    my @versions = sort {_versioncmp($b,$a)} keys %perls;

    # page perl perl version cross referenced with platforms
    my %perl_osname_all;
    for my $perl ( @versions ) {
        my (@data,%oscounter,%dist_for_perl);
        for my $dist ( sort keys %{ $perldata{$perl} } ) {
            my @osversion;
            for my $oscode ( sort keys %{ $perlos{$perl} } ) {
                if ( defined $data{$dist}{$perl}{$oscode} ) {
                    push @osversion, { ver => $data{$dist}{$perl}{$oscode} };
                    $oscounter{$oscode}++;
                    $dist_for_perl{$dist}++;
                } else {
                    push @osversion, { ver => undef };
                }
            }
            push @data, {
                dist      => $dist,
                osversion => \@osversion,
            };
        }

        my @perl_osnames;
        for my $code ( sort keys %{ $perlos{$perl} } ) {
            if ( $oscounter{$code} ) {
                push @perl_osnames, { oscode => $code, osname => $lookup{$code}, cnt => $oscounter{$code} };
                $perl_osname_all{$code}{$perl} = $oscounter{$code};
            }
        }

        my $destfile        = "perl_${perl}_platforms.html";
        $tvars{osnames}     = \@perl_osnames;
        $tvars{dists}       = \@data;
        $tvars{perl}        = $perl;
        $tvars{cnt_modules} = scalar keys %dist_for_perl;
        $tvars{cache}       = $cache;
        $tvars{content}     = 'cpan/stats-perl-platform.html';
        Transform( 'cpan/layout-stats-static.html', \%tvars, $destfile );
    }

    my @perl_osnames;
    for(keys %perl_osname_all) {
        my ($name,$code) = $cpan->OSName($_);
        push @perl_osnames, {oscode => $code, osname => $name}
    }

    my (@perls,@data_perlplat,$parms,$destfile);
    for my $perl ( @versions ) {
        push @perls, {
            perl         => $perl,
            report_count => $perls{$perl}{reports},
            distro_count => scalar( keys %{ $perls{$perl}{distros} } ),
        };

        my @count;
        for my $os (keys %perl_osname_all) {
            my ($name,$code) = $cpan->OSName($os);
            push @count, { oscode => $code, osname => $name, count => $perl_osname_all{$os}{$perl} };
        }
        push @data_perlplat, {
            perl => $perl,
            count => \@count,
        };

        my (@data_perl,$cnt);
        for my $dist ( sort keys %{ $perldata{$perl} } ) {
            $cnt++;
            push @data_perl, {
                dist    => $dist,
                version => $perldata{$perl}{$dist},
            };
        }

        # page per perl version
        $destfile           = "perl_${perl}.html";
        $tvars{data}        = \@data_perl;
        $tvars{perl}        = $perl;
        $tvars{cnt_modules} = $cnt;
        $tvars{cache}       = $cache;
        $tvars{content}     = 'cpan/stats-perl-version.html';
        Transform( 'cpan/layout-stats-static.html', \%tvars, $destfile );
    }

    # how many test reports per platform per perl version?
    $destfile       = "perl_platforms.html";
    $tvars{osnames} = \@perl_osnames;
    $tvars{perlv}   = \@data_perlplat;
    $tvars{cache}   = $cache;
    $tvars{content} = 'cpan/stats-perl-platform-count.html';
    Transform( 'cpan/layout-stats-static.html', \%tvars, $destfile );

    # generate index.html
    $destfile       = "index.html";
    $tvars{perls}   = \@perls;
    $tvars{cache}   = $cache;
    $tvars{content} = 'cpan/stats-index.html';
    Transform( 'cpan/layout-stats-static.html', \%tvars, $destfile );

#    # create symbolic links
#    for my $link ('headings', 'background.png', 'style.css', 'cpan-testers.css') {
#        my $source = file( $directory, $link );
#        my $target = file( $directory, 'stats', $link );
#        next    if(!-e $source);
#        next    if( -e $target);
#        eval {symlink($source,$target) ; 1};
#    }
}

sub RecentPage {
    my $cpan = Labyrinth::Plugin::CPAN->new();
    $cpan->Configure();

    # Recent reports
    my @recent;
    my $count = $settings{rss_limit_recent} || $RECENT;
    my $next = $dbi->Iterator('hash','GetRecent',{limit => "LIMIT $count"});

    while ( my $row = $next->() ) {

        next unless $row->{version};
        my ($name) = $cpan->OSName($row->{osname});

        my $report = {
            guid         => $row->{guid},
            id           => $row->{id},
            dist         => $row->{dist},
            status       => uc $row->{state},
            version      => $row->{version},
            perl         => $row->{perl},
            osname       => $name,
            osvers       => $row->{osvers},
            platform     => $row->{platform},
        };
        push @recent, $report;
        last    if(--$count < 1);
    }

    my $cache = sprintf "%s/static", $settings{webdir};
    mkpath($cache);

    $tvars{recent}  = \@recent;
    $tvars{cache}   = $cache;
    $tvars{content} = 'cpan/recent.html';

    Transform( 'cpan/layout-static.html', \%tvars, 'recent.html' );
    $tvars{recent} = undef;

    my $destfile = "$cache/recent.rss";
    overwrite_file( $destfile, _make_rss( 'recent', undef, \@recent ) );
}
 
#----------------------------------------------------------------------------
# Private Interface Functions

sub _request_count {
    my $dbi = shift;

    my @rows = $dbi->GetQuery('array','CountRequests');
    my $cnt = @rows ? $rows[0]->[0] : 0;
    return $cnt;
}

sub _request_oldest {
    my $dbi = shift;

    my @rows = $dbi->GetQuery('array','OldestRequest');
    my $cnt = @rows ? $rows[0]->[0] : 0;
    return $cnt;
}

sub _make_json {
    my ( $data ) = @_;
    return encode_json( $data );
}

sub _make_rss {
    my ( $type, $item, $data ) = @_;
    my ( $title, $link, $desc );

    if($type eq 'dist') {
        $title = "$item CPAN Testers Reports";
        $link  = "http://www.cpantesters.org/distro/".substr($item,0,1)."/$item.html";
        $desc  = "Automated test results for the $item distribution";
    } elsif($type eq 'recent') {
        $title = "Recent CPAN Testers Reports";
        $link  = "http://www.cpantesters.org/static/recent.html";
        $desc  = "Recent CPAN Testers reports";
    } elsif($type eq 'author') {
        $title = "Reports for distributions by $item";
        $link  = "http://www.cpantesters.org/author/".substr($item,0,1)."/$item.html";
        $desc  = "Reports for distributions by $item";
    } elsif($type eq 'nopass') {
        $title = "Failing Reports for distributions by $item";
        $link  = "http://www.cpantesters.org/author/".substr($item,0,1)."/$item.html";
        $desc  = "Reports for distributions by $item";
    }

    my $rss = XML::RSS->new( version => '1.0' );
    $rss->channel(
        title       => $title,
        link        => $link,
        description => $desc,
        syn         => {
            updatePeriod    => "daily",
            updateFrequency => "1",
            updateBase      => "1901-01-01T00:00+00:00",
        },
    );

    for my $test (@$data) {
        $rss->add_item(
            title => sprintf(
                "%s %s-%s %s on %s %s (%s)",
                map {$_||''}
                @{$test}{
                    qw( status dist version perl osname osvers platform )
                    }
            ),
            link => "$settings{reportlink2}/" . ($test->{guid} || $test->{id}),
        );
    }

    return $rss->as_string;
}

sub _versioncmp {
    my ($v1,$v2) = @_;
    my ($vn1,$vn2);

    $v1 =~ s/\s.*$//    if($v1);
    $v2 =~ s/\s.*$//    if($v2);

    return -1   if(!$v1 && $v2);
    return  0   if(!$v1 && !$v2);
    return  1   if($v1 && !$v2);

    eval { $vn1 = version->parse($v1); };
    if($@) { return $v1 cmp $v2 }
    eval { $vn2 = version->parse($v2); };
    if($@) { return $v1 cmp $v2 }

    return $vn1 cmp $vn2;
}

1;

__END__

=head1 SEE ALSO

  Labyrinth

=head1 AUTHOR

Barbie, <barbie@missbarbell.co.uk> for
Miss Barbell Productions, L<http://www.missbarbell.co.uk/>

=head1 COPYRIGHT & LICENSE

  Copyright (C) 2008-2012 Barbie for Miss Barbell Productions
  All Rights Reserved.

  This module is free software; you can redistribute it and/or
  modify it under the Artistic License 2.0.

=cut