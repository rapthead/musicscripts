#!/usr/bin/perl
use strict;
#use warnings;
#use utf8;
#use open qw(:std :utf8);
use Data::Dumper;

use Image::Magick;
#use DBI;
use File::Find;
use File::Spec;
use File::Basename;
use Audio::FLAC::Header;
use POSIX;
#use Encode qw(encode_utf8 decode_utf8);
use DateTime;

use FindBin;
use lib "$FindBin::RealBin/lib";

use MusicDB;
#use CueParse;
use CueParse2;

my $music_lib_dir = '/home/music/lossless/';
my $covers_dir = $ENV{'HOME'}.'/covers/';
my $dbpath = $ENV{'HOME'}.'/play_stat.db';

if ($dbpath) { MusicDB->change_db_path( $dbpath ); }
MusicDB->init_objects;

sub artUrgency {
    my ($dir, $albumartist, $albumtitle) = @_;
    $dir = dirname($dir) if basename($dir) =~ m/^cd\d+$/;
    my $coverPath;
    my $covername = "$albumartist-$albumtitle.jpg";
    $covername =~ tr#][\/:<>?*|#_#;

    my @exts = ('jpg', 'jpeg', 'png', 'tiff');
    foreach my $ext (@exts) {
        if ( -r $dir.'/covers/front.'.$ext ) {
            $coverPath = $dir.'/covers/front.'.$ext;
        }
    }
    unless ($coverPath) {
        foreach my $ext (@exts) {
            if ( -r $dir.'/covers/front(out).'.$ext ) {
                $coverPath = $dir.'/covers/front(out).'.$ext;
            }
        }
    }
    unless ($coverPath) {
        warn "Не найдена обложка [$dir]\n";
        return;
    }
    rsize($coverPath,$covers_dir.$covername)
        if (! -e $covers_dir.$covername);
}

sub update_track($$) {
    my ($track, $track_info) = @_;

    if (!$track->length) { $track->length($track_info->{length}); }
    elsif ($track->length != $track_info->{length}) 
    { die "изменилась продолжительность файла [", $track_info->{uri}, "], требуется ручное исправление ошибки\n" }

    my $is_track_changed = 0;
    my @fields = ('title', 'disc', 'track_artist', 'rg_peak', 'rg_gain');
    foreach my $field (@fields) {
        if ($track_info->{$field} ne $track->$field) {
            warnchanges($field, $track->$field, $track_info->{$field});
            $track->$field($track_info->{$field});
            $is_track_changed = 1;
        }
    }
    warn "У файла [", $track_info->{uri}, "] изменены метаданные трека\n"
        if ($is_track_changed);
    if ($track_info->{uri} ne $track->uri) {
        $track->uri($track_info->{uri});
        warn "[", $track->uri, "] -> [", $track_info->{uri}, "] был перенесен\n";
        $is_track_changed = 1;
    }
    return 1 if ($is_track_changed);
    return 0;
}

sub warnchanges($$$) {
    warn sprintf("%s: %s -> %s\n",@_);
}

sub main {
    my @cueFiles;
    sub wanted { push(@cueFiles,$File::Find::name) if (/\.cue$/ && -r); }
    find(\&wanted, $music_lib_dir);#.'cd/what.cd/Slightly Stoopid/2015-Meanwhile... Back at the Lab/');
    @cueFiles = sort @cueFiles;

    foreach (@cueFiles) {
        my $cueFile = $_;
        my $cueDir = dirname($cueFile);
        my $cueHash = parseCue($cueFile);

        #artUrgency($cueDir, $cueHash->{'artist'}, $cueHash->{'album'});
        $cueHash->{'album'}->{'REM'}->{'DATE'} =~ m/(\d{4})(?:-(\d{4}))?/;
        my $cue_info = {
            tracks => [],
            album => {
                genre       => $cueHash->{'album'}->{'REM'}->{'GENRE'},
                title       => $cueHash->{'album'}->{'TITLE'},
                date        => DateTime->new(year => $1),
                release_date=> DateTime->new(year => $2 || $1),
                is_changed  => 0,
                db_object   => undef
            },
            artist => {
                name => $cueHash->{'album'}->{'PERFORMER'},
                is_changed  => 0,
                db_object   => undef
            }
        };
        $cueHash->{'album'}->{'REM'}->{'REPLAYGAIN_ALBUM_GAIN'} =~ s/\s*db$//;
        $cue_info->{'album'}->{'rg_peak'} = $cueHash->{'album'}->{'REM'}->{'REPLAYGAIN_ALBUM_PEAK'}+0
            if ($cueHash->{'album'}->{'REM'}->{'REPLAYGAIN_ALBUM_PEAK'});
        $cue_info->{'album'}->{'rg_gain'} = $cueHash->{'album'}->{'REM'}->{'REPLAYGAIN_ALBUM_GAIN'}+0
            if ($cueHash->{'album'}->{'REM'}->{'REPLAYGAIN_ALBUM_GAIN'});

        warn "processing: ", $cue_info->{artist}->{name}, ' - ',$cue_info->{album}->{title},"\n";

        foreach my $track (@{$cueHash->{'tracks'}}) {
            my $trackFile = '';
            if (defined $track->{'INDEX'}->[1] && $track->{'track'}->{'datatype'} == 'AUDIO') {
                $trackFile = $cueHash->{'files'}->[$track->{'INDEX'}->[1]->{'fileindex'}]->{'filename'};

                my $trackFilePath = File::Spec->catfile($cueDir,$trackFile);
                if (! -e $trackFilePath) { warn "Файл [", $trackFilePath, "] не найден!\n"; }
                elsif (! -f $trackFilePath) { warn "[", $trackFilePath, "] не является файлом!\n"; }
                else {
                    my $flacHeader = Audio::FLAC::Header->new($trackFilePath);
                    my $trackUri = File::Spec->abs2rel($trackFilePath,$music_lib_dir);
                    my $trackInfo = {
                        track_artist=> ($track->{'PERFORMER'} eq $cueHash->{'album'}->{'PERFORMER'}) ?
                            '':($track->{'PERFORMER'}),
                        title       => $track->{'TITLE'},
                        track_num   => $track->{'TRACK'}->{'number'},
                        disc        => $cueHash->{'album'}->{'REM'}->{'DISCNUMBER'} || 1,
                        length      => ceil($flacHeader->{'trackTotalLengthSeconds'}),
                        uri         => $trackUri,
                        processed   => 0,
                        is_changed  => 0,
                        db_object   => undef
                    };
                    $track->{'REM'}->{'REPLAYGAIN_TRACK_GAIN'} =~ s/\s*db$//;
                    $trackInfo->{'rg_peak'} = $track->{'REM'}->{'REPLAYGAIN_TRACK_PEAK'}+0
                        if ($track->{'REM'}->{'REPLAYGAIN_TRACK_PEAK'});
                    $trackInfo->{'rg_gain'} = $track->{'REM'}->{'REPLAYGAIN_TRACK_GAIN'}+0
                        if ($track->{'REM'}->{'REPLAYGAIN_TRACK_GAIN'});
                    push @{$cue_info->{tracks}}, $trackInfo;
                }
            }
            elsif ($track->{'TRACK'}->{'datatype'} ne 'AUDIO') {
                warn "Трек ".$track->{'TRACK'}->{'number'}." не является аудио-файлом\n";
            }
            else {
                warn "У трека ".$track->{'TRACK'}->{'number'}." нет файла\n";
            }
        }

        my @album_uris = map { $_->{uri} } @{$cue_info->{'tracks'}};
        my $db_track_search_by_uri = Track::Manager->get_tracks(
            query => [ 'uri' => \@album_uris ],
            require_objects => [ 'album.artist' ],
        );

        my @album_tracks = ();
        foreach my $db_track (@$db_track_search_by_uri) {
            my @cue_tracks = grep { $_->{uri} eq $db_track->uri } @{$cue_info->{tracks}};
            # трек не найден
            if (@cue_tracks!=1) {
				print Dumper $cueHash;
				#print Dumper $cue_info->{tracks};
				die "Что-то пошло не так, треки с одинаковым uri\n"; 
			}

            my $cur_track = $cue_tracks[0];
            if (update_track($db_track, $cur_track)) {
                $cur_track->{is_changed} = 1;
            }
            $cur_track->{db_object} = $db_track;
            $cur_track->{processed} = 1;
            push @album_tracks, $cur_track;

            $cue_info->{album}->{db_object} = $db_track->album
                if (!$cue_info->{album}->{db_object});

            $cue_info->{artist}->{db_object} = $db_track->album->artist
                if (!$cue_info->{artist}->{db_object});
        }

        my @not_found_by_uri = grep { !$_->{processed} } @{$cue_info->{tracks}};
        foreach my $cur_track (@not_found_by_uri) {
            my $db_track_search = Track::Manager->get_tracks(
                query =>
                [
                    track_num       => $cur_track->{'track_num'},
                    disc            => $cur_track->{'disc'},
                    'album.title'   => $cue_info->{'album'}->{'title'},
                    'album.release_date'=> $cue_info->{'album'}->{'release_date'},
                    'album.date'   => $cue_info->{'album'}->{'date'}
                ],
                require_objects => [ 'album.artist' ],
            );
            if (@$db_track_search>1)
            { die "Найдено больше одного соответствия [", $cur_track->{'uri'}, "]\n"; }
            # найдено соответствие в базе
            elsif (@$db_track_search==1) { 
                my $db_track = $db_track_search->[0];
                if (update_track($db_track, $cur_track)) {
                    $cur_track->{db_object} = $db_track;
                }
            }
            # не найдено соответствие в базе
            else {
                $cur_track->{db_object} = Track->new();
                foreach (('track_artist', 'title', 'track_num', 'disc', 'length', 'uri', 'rg_peak', 'rg_gain')) {
                    warnchanges($_,'',$cur_track->{$_});
                    $cur_track->{db_object}->$_($cur_track->{$_});
                }
            }
            $cur_track->{processed} = 1;
            $cur_track->{is_changed} = 1;

            if (! defined($cur_track->{db_object}->album) ) {
                if ( $cue_info->{album}->{db_object} ) {
                    $cur_track->{db_object}->album($cue_info->{album}->{db_object});
                }
                else { $cur_track->{db_object}->album(Album->new()); }
            }

            $cue_info->{album}->{db_object} = $cur_track->{db_object}->album
                if (!$cue_info->{album}->{db_object});

            if (! defined($cue_info->{album}->{db_object}->artist) ) {
                if ( $cue_info->{artist}->{db_object} ) {
                    $cue_info->{album}->{db_object}->artist($cue_info->{artist}->{db_object});
                }
                else {
                    my $artist = Artist->new('name' => $cue_info->{artist}->{name});
                    if ( $artist->load(speculative => 1) ) {
                        $cue_info->{album}->{db_object}->artist_id($artist->artist_id); 
                    }
                    $cue_info->{artist}->{db_object} = $artist;
                }
            }

            $cue_info->{artist}->{db_object} = $cur_track->{db_object}->album->artist
                if (!$cue_info->{artist}->{db_object});
        }

        my $album = $cue_info->{album}->{db_object};
        my @fields = ('title', 'date', 'release_date', 'genre', 'rg_peak', 'rg_gain');
        foreach my $field (@fields) {
            if ($cue_info->{album}->{$field} ne $album->$field) {
                warnchanges("album.".$field,$album->$field?$album->$field:'',$cue_info->{album}->{$field});
                $album->$field($cue_info->{album}->{$field});
                $cue_info->{album}->{is_changed} = 1;
            }
        }

        my $artist = $cue_info->{artist}->{db_object};
        if ($artist->name ne $cue_info->{artist}->{name} || !$artist->artist_id) {
            warnchanges("artist.name",$artist->name,$cue_info->{artist}->{name});
            $artist->name($cue_info->{artist}->{name});
            $artist->artist_id(undef);
            $cue_info->{artist}->{is_changed} = 1;
            $cue_info->{album}->{is_changed} = 1;
        }

        if ($cue_info->{artist}->{is_changed}) { 
            #$Rose::DB::Object::Debug = 1;
            $artist->save( insert => 1 );
            #$Rose::DB::Object::Debug = 0;

            $album->artist_id($artist->artist_id());
            $cue_info->{album}->{is_changed} = 1;
        }

        if ($cue_info->{album}->{is_changed}) {
            $album->isactive(1);
            $album->save();
            $_->{db_object}->album_id($album->album_id()) foreach (@{$cue_info->{tracks}});
        }

        foreach (@{$cue_info->{tracks}}) {
            $_->{db_object}->save if ($_->{is_changed});
        }
    }
}

main();
#clean_db();

warn "актуализация завершена успешно\n";
