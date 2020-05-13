# get_iplayer-to-kodi-converter
## Summary
A Perl program which takes TV programmes downloaded by get_iplayer and renames and reorganises them in a way that makes them compatible with Kodi media centre.
## License
The contents of this repository are licensed under the GNU General Public License v3.0
## Abstract
This Perl program takes films, television and radio programmes downloaded by the get_iplayer utility from the BBC iPlayer website that have been saved with the default filename format of `<name>_-_<episode>_<pid>_<version>.ext` and renames and reorganises them in a way that that should make them more compatible with Kodi media centre.

The program only works on media files of the default type downloaded by `get_iplayer`, namely `.mp4` video files for films and TV programmes and `.m4a` audio files for radio programmes.

Note that names presented in angle brackets refer to the iPlayer XML tags from which the information is derived.

The program requires `get_iplayer` to be installed on the system. If it is not found in `$PATH` then a custom path can be specified as a command line argument. The program will never use `get_iplayer` to download a media file, only metadata files. 

The default behaviour of the program is to *copy* the files to the destination directory. This can be changed to moving the files by specifying an optional command line argument.

The program obtains the information required to correctly rename and reorganise the media file from the associated `.xml` XML metadata file that get_iplayer can optionally download with the media file. If the XML metadata file has not already been downloaded then the program will attempt to extract the 8 character alphanumeric BBC PID (Programme ID) from the media file's filename and download the XML metadata file. Additionally, if any existing XML metadata file is found to be out-of-date, the program will attempt to download a new up-to-date version and will preserve the old one by adding the suffix `.old` to it.

If no iPlayer XML metadata file exists for a particular media file and the program cannot download one, then that media file will be ignored (This may  be addressed in a later program version). For now, it is recommended to use one of the many other media library organising programs that are available.

The program will also use the metadata contained within the iPlayer XML metadata file to create a Kodi `.nfo` NFO metadata file for each media file. For films this will be of the Kodi type `<movie>` and for TV and radio programmes, this will be of the Kodi type `<episodedetails>`. The user can then configure Kodi to use this `.nfo` file in preference to web-scraped programme information if they wish.

Note that `get_iplayer` used to have the ability to create its own semi- Kodi compatible `.nfo` metadata file for each media file. Any surviving `get_iplayer` generated `.nfo` metadata files are ignored but preserved by adding the suffix `.old`.

In addition to downloading any missing iPlayer XML metadata files, the program will also download the following metadata files associated with each programme if they do not already exist alongside the media file:
- jpg (used as a Kodi 'fanart' image)
- series.jpg (used as a Kodi season 'fanart' image, TV and radio series only)
- square.jpg (used as a Kodi 'thumb' image for radio programmes only)
- srt (used as a Kodi subtitle file, TV and radio programmes only)
- tracks.txt (not used by Kodi, downloaded for completeness)
- cue (not used by Kodi, downloaded for completeness, radio programmes only)
- credits.txt (not used by Kodi, downloaded for completeness)

Note that some associated metadata files do not exist for some programmes and that some that do exist are only downloadable if the programme is currently available on iPlayer (e.g. srt). In addition, an existing jpg metadata file will be re-downloaded and *silently overwritten* if it is less than 1920x1080 pixels.

If the program detects that a media file is a film, it will be renamed to `<name>_(<firstbcastyear>).mp4` and copied or moved to a new directory of the same name within the films subdirectory of the destination directory.

Any films the program reorganises will be organised as follows. Remember, not all metadata files will be available for all films.
```
/destinationdir
    /films
        /<title>_(<firstbcastyear>)
            <title>_(<firstbcastyear>).mp4
            <title>_(<firstbcastyear>).srt
            <title>_(<firstbcastyear>)-fanart.jpg
            <title>_(<firstbcastyear>).tracks.txt
            <title>_(<firstbcastyear>).credits.txt
            <title>_(<firstbcastyear>).xml
            <title>_(<firstbcastyear>).xml.old
            <title>_(<firstbcastyear>).nfo
            <title>_(<firstbcastyear>).nfo.old
        /<title>_(<firstbcastyear>)
            <title>_(<firstbcastyear>).mp4
            <title>_(<firstbcastyear>).srt
            <title>_(<firstbcastyear>)-fanart.jpg
            <title>_(<firstbcastyear>).tracks.txt
            <title>_(<firstbcastyear>).credits.txt
            <title>_(<firstbcastyear>).xml
            <title>_(<firstbcastyear>).xml.old
            <title>_(<firstbcastyear>).nfo
            <title>_(<firstbcastyear>).nfo.old
```
If the program detects that a media file is a TV or radio programme, it will be renamed to `<name>_(<firstbcastyear>)_<sesort>_<episodeshort>.mp4` (where `<episodeshort>` is only used if it is a unique value and not a generic "Episode N" string) and copied or moved to a new directory of the same name within a series directory within a programme `<brand>` subdirectory within the TV or radio subdirectory of the destination directory.

Any TV or radio the program reorganises will be organised as follows. Remember, not all metadata files will be available for all films.
```
/destinationdir
    /tv
        /<brand>
            season<seriesnum>-fanart.jpg
            season<seriesnum>-fanart.jpg
            /Series_<seriesnum>
                /<name>_(<firstbcastyear>)_<sesort>_<episodeshort>
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.mp4
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.srt
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>-fanart.jpg
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.tracks.txt
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.cue
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.credits.txt
            /Series_<seriesnum>
                /<name>_(<firstbcastyear>)_<sesort>_<episodeshort>
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.mp4
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.srt
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>-fanart.jpg
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.tracks.txt
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.cue
                    <name>_(<firstbcastyear>)_<sesort>_<episodeshort>.credits.txt
```
For programmes that are one-offs or do not have series information contained within the XML metadata file, then the series directory will be omitted. This should not be a problem as Kodi media centre ignores the series directory (and whatever its name is).

## Caveats
The program is limited by the accuracy and completeness of the data provided within the iPlayer XML metadata files. For some programmes, manual renaming will still have to be carried out if the programme is to be recognised by Kodi media centre and the online sources (e.g. thetvdb.com) it uses to obtain additional programme information.

For some programmes, the BBC have not maintained a consistent naming or numbering scheme for each series over the years (e.g. "Natural World") and for others while the BBC's naming is consistent and rational, it does not match the series numbering on thetvdb.com (e.g. Coast Series NN Reversions or are all 'Series Zero' special episodes on thetvdb.com)

Do not attempt to use the program over a VPN due to the BBC's tendency to block access to iPlayer from some known VPN providers.

## Command Line Arguments
- The following command line arguments are required for the proper functioning of this program:
- `--source [FILE|DIRECTORY]` : Mandatory, more than one allowed. Specifies a media file or directory of media files to convert.
- `--destination [DIRECTORY]` : Mandatory. Specifies the destination directory in which the converted media files will be placed.

- The following command line arguments can optionally be added to adjust the functioning of this program:
- `--behaviour [copy|move]` : Optional, default is copy. Specifies whether media files are copied or moved to the destination directory.
- `--recurse` : Optional. When specified, the program will recurse in to subdirectories of the source directory to search for media files.
- `--download-missing-metadata [yes|no]` : Optional, default is yes. Specifies whether get_iplayer will be used to try to download missing cue, tracks.txt and credits.txt metadata files.
- `--force-type [film|tv|radio]` : Optional. Forces the program to process all media files according to 'film', 'tv' or 'radio' rules, regardless of their actual type.
- `--get-iplayer [PATH]` : Optional. Allows the user to provide the location of get_iplayer if it is installed outside of the system's \$PATH.
- `--separator ['_'|'.'|' ']` : Optional, default is underscore `'_'`. Specifies the separator character used between words in the destination file and directory names. The choises are undersore `'_'`, period `'.'` and whitespace `' '`.
- `--subdir-films [subdirectory_name]` : Optional, default is 'films'. Specifies a custom subdirectory name for films within the destination directory.
- `--subdir-tv [subdirectory_name]` : Optional, default is 'tv'. Specifies a custom subdirectory name for TV programmes within the destination directory.
- `--subdir-films [directory name]` : Optional, default is 'radio'. Specifies a custom subdirectory name for radio programmes within the destination directory.

## Useful Links
- get_iplayer https://github.com/get-iplayer/get_iplayer
- Kodi media centre https://kodi.tv

## Compatibility
The program has been tested with perl 5, version 30, subversion 1 (v5.30.1) built for x86_64-linux-thread-multi on OpenSuSE Tumbleweed