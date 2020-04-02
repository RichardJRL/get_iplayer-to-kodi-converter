#!/usr/bin/perl

use warnings;
use strict;
use autodie;
use File::Basename;
use File::Spec;
use File::Copy;
use File::Path;
use Data::Dumper;
use HTML::Entities;
use LWP::Simple;
use XML::LibXML;

#NB: Can copy operations and directory creation be carried out while preserving timestamps?

# variables to hold command line arguments
my $claConvert = 0;     # Convert get_iplayer to Plex format. Boolean, 0=false, 1=true 
my $claRevert = 0;      # (Attempt to) revert Plex format to get_iplayer. Boolean, 0=false, 1=true
my $claRecurse = 0;     # Recurse into subdirectories of source directory. Boolean, 0=false, 1=true 
# Command line arguments for type detection and directory selection are commented out as the categorisation and sorting are now automatic
# TODO: Delete once categorisation and sorting logic confirmed working
# my @claType;            # Array to hold unchecked content type values
# my $claTypeFilm = 0;    # Force conversion of files according to Film conversion rules
# my $claTypeTv = 0;      # Force conversion of files according to TV programme conversion rules
# my $claTypeMusic = 0;   # Force conversion of files according to Music conversion rules
# TODO: implement command line arguments for custom subdirectory names
my $claDirFilm ;        # Custom name for the directory to hold films
my $claDirTv;           # Custom name for the directory to hold TV programmes
my $claDirMusic;        # Custom name for the directory to hold music, radio programmes and podcasts
my @claSource;          # Array of File::Spec objects representing source files or directories to search for media to convert
my @claDestination;     # File::Spec object for the base destination directory of converted media
my $claInvalid = 0;     # Counter for invalid command line arguments.
my $claErrors = 0;      # Counter for errors in valid command line arguments
my $claGetIplayer;      # Custom path to an instance of get_iplayer to be used in preference to any other instance of it on the system.

# variables to hold files and directories to work on
my @sourceDirs;         # Only the valid source directories harvested from the command line arguments
my @completeListOfDirs; # Entire list of all source directories found when getMediaFiles called (used for debug purposes only)
my @sourceMediaFiles;
my $destinationDir;
my $destinationDirFilm = 'films';
my $destinationDirTv = 'tv';
my $destinationDirMusic = 'radio';


# other major variables
my $get_iplayer;           # full path to the get_iplayer program 
my $programDirectoryFullPath = File::Spec->rel2abs(dirname(__FILE__));

# kodi template nfo metadata files loaded into strings as required
my $kodiNfoTemplateFilm;
my $kodiNfoTemplateTv;
my $kodiNfoTemplateMusicArtist;
my $kodiNfoTemplateMusicAlbum;
my $kodiNfoTemplateMusicVideo;

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: get list of media files and directories from the current subdirectory
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Arguments:
# $_[0] = Directory to search
#
# Return Value:
# None.
#
# Notes: @completeListOfDirs and @sourceMediaFiles are updated internally, and 
#        recursion behaviour is set via the command line argument --recurse  
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ 
sub getMediaFiles {
    print("INFO: Subroutine getMediaFiles: Gathering list of media files to process.\n");
    if($claRecurse) {
        print("INFO: Subroutine getMediaFiles: Behaviour is set to recurse into any subdirectories found.\n");
    }
    else {
        print("INFO: Subroutine getMediaFiles: Behaviour is set to ignore any subdirectories found.\n");
    }
    
    my $currentDir = $_[0];
    if($currentDir !~ /\/\Z/) {
        $currentDir .= '/';
    }
    my $dh;
    opendir($dh, $currentDir);
    while(my $path = readdir($dh)) {
        if($path =~ m/\A\.{1,2}\Z/) {    # ignore dotted current (.) and parent (..) dirs
            next;
        }
        $path = $currentDir . $path;
        $path = File::Spec->rel2abs($path);
        if(-f $path) {
            if($path =~ m/\.mp4\Z/ || $path =~ m/\.m4a\Z/) {
                push(@sourceMediaFiles, $path);
            }
        }
        elsif(-d $path) {
            if($claRecurse == 1) {
                push(@completeListOfDirs, $path);
                getMediaFiles($path);
            }
        }
        else {  # found something odd
            print("WARNING: Subroutine getMediaFiles: Found a path that is neither a file nor a directory: $path\n");
        }
    }
    closedir($dh);
    @completeListOfDirs = sort(@completeListOfDirs);
    @sourceMediaFiles = sort(@sourceMediaFiles);
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: getMetadata: get contents of an XML metadata tag from an XML file
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Description:
# Given an array of XML tags and an XML document, search for each tag in turn 
# and return the text contents of the first non-empty tag found.
#
# Arguments:
# $_[0] = Reference to a string containing an XML document
# $_[1] = Reference to an array of XML tag names to search for
#
# Return Value:
# A string containing the text contents of the first non-empty tag from the XML
# tag array that has been found in the XML document.
# Or undef if none of the XML tags from the array of XML tags to search for
# were found or none of them contained any text in the XML document.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub getMetadata {
    if(!defined(${$_[0]})) {
        print("ERROR: Subroutine getMetadata: No reference to an XML document defined as an argument. Cannot search for tags if no XML document supplied.\n");
        return undef;
    }

    my ($xmlDocumentReference, @xmlTagsToFind) = @_;
        
    if(@xmlTagsToFind == 0) {
        print("ERROR: Subroutine getMetadata: No reference to an array of XML tag names to search for supplied as an argument.\n");
        return undef;
    }

    # Load and prepare XML document
    my $xmlParser = XML::LibXML->new();
    my $xmlDom = $xmlParser->load_xml(string => "${$xmlDocumentReference}", no_blanks => 1);
    my $xmlMetadata = $xmlDom->documentElement();

    # Variables for search results
    my @xmlTextNodeSearchResultsArray;
    my @xmlElementNodeSearchResultsArray;

    # pretty tag list for messages.
    my $prettyTagList = '<' . join('>, <', @xmlTagsToFind) . '>';
    print("INFO: Subroutine getMetadata: Attempting to search the XML tags $prettyTagList to return the first text found.\n");

    foreach my $tag (@xmlTagsToFind) {
        @xmlTextNodeSearchResultsArray = $xmlMetadata->findnodes("$tag/text()");
        if(@xmlTextNodeSearchResultsArray == 0) {
            print("WARNING: Subroutine getMetadata: No XML tags <$tag> containing text found.\n");
            next;
        }
        else {
            print("SUCCESS: Subroutine getMetadata: Found " . @xmlTextNodeSearchResultsArray . " XML tags <$tag> containing text.\n");
            foreach my $textNode (@xmlTextNodeSearchResultsArray) {
                print("SUCCESS: Subroutine getMetadata: Text contents of the XML tag <$tag> are: $textNode\n");
            }
            # Use to_literal() if '&' instead of '&amp;' needed in the output
            print("SUCCESS: Subroutine getMetadata: Returning the text contents of the *first* XML <$tag> tag found: " . $xmlTextNodeSearchResultsArray[0]->toString() . "\n");
            return $xmlTextNodeSearchResultsArray[0]->toString();
        }  
    }
    # Should only get here if none of the tags specified in the tags to search for array have been found.
    print("ERROR: Subroutine getMetadata: No $prettyTagList XML tags containing text found.\n");
    return undef;
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: setMetadataSingle: Set contents of a single XML metadata tag in a XML file
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Description:
# Set the contents of a single XML metadata tag in an XML file. It will create
# the tag if it does not already exist and remove empty duplicate tags if necessary.
# Arguments:
# $_[0] = Reference to a string containing the XML document
# $_[1] = XML tag name to search for
# $_[2] = Data to be written to the XML tag
# Return Value:
# On failure, returns a boolean false = 0, on success, returns a boolean true = 1
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub setMetadataSingle {
    if(!defined(${$_[0]})) {
        print("ERROR: Subroutine setMetadataSingle: No XML document defined as an argument.\n");
        return undef;
    }
    if(!defined($_[1])) {
        print("ERROR: Subroutine setMetadataSingle: No XML tag defined as an argument.\n");
        return undef;
    }
    if(!defined($_[2])) {
        print("ERROR: Subroutine setMetadataSingle: No text string defined as an argument.\n");
        return undef;
    }

    my $xmlDocumentReference = $_[0];
    my $tagToFind = $_[1];
    my $textToAdd = $_[2];
    
    # Load and prepare XML document
    my $xmlParser = XML::LibXML->new();
    my $xmlDom = $xmlParser->load_xml(string => "${$xmlDocumentReference}", no_blanks => 1);
    my $xmlMetadata = $xmlDom->documentElement();

    # Variables for search results
    my @xmlTextNodeSearchResultsArray;
    my @xmlElementNodeSearchResultsArray;

    # First search for tag with existing text, including '/text()' ensures only text-containing Text Nodes are returned.
    print("INFO: Subroutine setMetadataSingle: Searching for <$tagToFind> XML tags with existing text.\n");
    @xmlTextNodeSearchResultsArray = $xmlMetadata->findnodes("$tagToFind/text()");
    if(@xmlTextNodeSearchResultsArray == 0) {
        print("WARNING: Subroutine setMetadataSingle: No <$tagToFind> XML tags with existing text found.\n");
    }
    elsif(@xmlTextNodeSearchResultsArray == 1) {
        print("SUCCESS: Subroutine setMetadataSingle: Found <$tagToFind> XML tag with the text: " . $xmlTextNodeSearchResultsArray[0]->toString() . "\n");
        print("SUCCESS: Subroutine setMetadataSingle: Replacing contents of <$tagToFind> XML tag with the text: " . $textToAdd . "\n");
        $xmlTextNodeSearchResultsArray[0]->setData($textToAdd);
        ${$xmlDocumentReference} = $xmlDom->toString(1);
        return 1;
    }
    else {
        print("ERROR: Subroutine setMetadataSingle: Found " . @xmlTextNodeSearchResultsArray . " <$tagToFind> XML tags with the text. Only one matching XML tag expected.\n");
        print("ERROR: Subroutine setMetadataSingle: Use setMetadataMultiple to add additional tags instead.\n");
        return undef;
    }

    # If subroutine has reached here then NO text-containing Text Nodes should have been found. Now search for empty Element Nodes
    print("INFO: Subroutine setMetadataSingle: Searching for <$tagToFind> XML tags without existing text.\n");
    @xmlElementNodeSearchResultsArray = $xmlMetadata->findnodes("$tagToFind");
    if(@xmlElementNodeSearchResultsArray == 0) {
        print("WARNING: Subroutine setMetadataSingle: No <$tagToFind> XML tags without existing text found.\n");
        # Proceed to next stage, adding a new node
    }
    elsif(@xmlElementNodeSearchResultsArray == 1) {
        print("SUCCESS: Subroutine setMetadataSingle: A single empty <$tagToFind> XML tag has been found, adding the new text: \'$textToAdd\' to it.\n");
        $xmlElementNodeSearchResultsArray[0]->appendText($textToAdd);
        ${$xmlDocumentReference} = $xmlDom->toString(1);
        return 1;
    }
    else {
        my $nodeCounter = 0;
        # More than one empty tag of the same type... this should never happen unless something has gone wrong, can tidy it up rather than throwing an error!
        foreach my $elementNode (@xmlElementNodeSearchResultsArray) {
            if($nodeCounter == 0) {
                print("SUCCESS: Subroutine setMetadataSingle: Added the following text to the XML tag <$tagToFind>: $textToAdd\n");
                $elementNode->appendText($textToAdd);
            }
            else {
                print("INFO: Subroutine setMetadataSingle: Removing empty, duplicate XML tag <$tagToFind>\n");
                $xmlMetadata->removeChild($elementNode);
            }
            $nodeCounter++;
        }
        ${$xmlDocumentReference} = $xmlDom->toString(1);
        return 1;
    }
    
    # If here, then no tag has been found, empty or otherwise. Add a new tag containing the required text
    print("SUCCESS: Subroutine setMetadataSingle: Added a brand new <$tagToFind> XML tag with the text: $textToAdd\n");
    my $newElement = $xmlDom->createElement($tagToFind);
    $newElement->appendText("$textToAdd");
    $xmlMetadata->insertAfter($newElement, $xmlMetadata->lastChild());

    # Repair the indenting of the the XML document now that a new element has been added
    # Required only if load_xml has not used 'no_blanks => 1' to open the XML document at the start of the subroutine
    # The method below has trouble with nesting elements that have their own child tags... (see </actor>)
    # foreach my $node ($xmlMetadata->childNodes()) {
    #     if ($node->nodeType != XML_ELEMENT_NODE) {
    #         $xmlMetadata->removeChild($node);
    #     }
    # }
    # This is better 
    # foreach($xmlMetadata->findnodes('//text()')) {
    #     $_->parentNode->removeChild($_) unless /\S/;
    # }

    # Should have successfully added the text to the tag if the subroutine has got to this point.
    ${$xmlDocumentReference} = $xmlDom->toString(1);
    return 1;
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: setMetadataMultiple: Set contents of a single XML file metadata tag,
#             creating multiple additional instances of the tag if required.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Description:
# Find a single named XML tag and overwrite its contents or append new tags with
# the same name to the document with their contents each being a single element
# of the array of data passed to the subroutine.
# Arguments:
# $_[0] = Reference to a string containing XML for XML file (output)
# $_[1] = XML tag the data is to be written to
# $_[2] = Reference to an array containing the data to be written to the XML tags
# $+[3] = 'OVERWRITE' || 'APPEND'. Governs whether existing Text Nodes survive
#         with their contents intact
# Return Value:
# On failure, returns a boolean false = 0, on success, returns a boolean true = 1
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Find a single XML tag and add additional copies of it with different text contents
# First Argument: Reference to a string containing the XML document
# Second Argument: Tag name to search for
# Third Argument: Reference to a list of values to be written to new copies of the named tag
# Fourth Argument: 'OVERWRITE' || 'APPEND'. Governs whether existing Text Nodes survive with contents intact
# Return Value: Ingeger for boolean false = 0, boolean true = 1
sub setMetadataMultiple {
    if(!defined(${$_[0]})) {
        print("ERROR: Subroutine setMetadataMultiple: No XML document defined as an argument.\n");
        return undef;
    }
    if(!defined($_[1])) {
        print("ERROR: Subroutine setMetadataMultiple: No XML tag name defined as an argument.\n");
        return undef;
    }
    if(@{$_[2]} == 0) {
        print("ERROR: Subroutine setMetadataMultiple: No array of tag contents defined as an argument.\n");
        return undef;
    }
    if(!defined($_[3])) {
        print("ERROR: Subroutine setMetadataMultiple: No behaviour \'OVERWRITE\' or \'APPEND\' defined as an argument.\n");
        return undef;
    }

    my $xmlDocumentReference = $_[0];
    my $tagToFind = $_[1];
    my @arrayOfTextToAdd = @{$_[2]};
    my $behaviour = $_[3];
    chomp($behaviour);

    if($behaviour =~ m/\AOVERWRITE\Z/ || $behaviour =~ m/\AAPPEND\Z/) {
        # Correct value, carry on
    }
    else {
        print("ERROR: Subroutine setMetadataMultiple: Behaviour must be either \'OVERWRITE\' or \'APPEND\'. Invalid behaviour received: \'$behaviour\'\n");
        return undef;
    }
    
    # Load and prepare XML document
    my $xmlParser = XML::LibXML->new();
    my $xmlDom = $xmlParser->load_xml(string => "${$xmlDocumentReference}", no_blanks => 1);
    my $xmlMetadata = $xmlDom->documentElement();

    # Variables for search results
    my @xmlTextNodeSearchResultsArray;
    my @xmlElementNodeSearchResultsArray;

    my $prettyListOfTextToAdd = join(', ', @arrayOfTextToAdd);
    $prettyListOfTextToAdd =~ s/, \Z//;

    print("INFO: Subroutine setMetadataMultiple: Attempting to add the text \'" . $prettyListOfTextToAdd . "\' to an existing or new <$tagToFind> XML tag.\n");

    # First search for tag with existing text, including '/text()' ensures only text-containing Text Nodes are returned.
    print("INFO: Subroutine setMetadataMultiple: Searching for <$tagToFind> XML tags with existing text.\n");
    
    my $nodeToInsertAfter;
    @xmlTextNodeSearchResultsArray = $xmlMetadata->findnodes("$tagToFind/text()");
    @xmlElementNodeSearchResultsArray = $xmlMetadata->findnodes("$tagToFind");
    if (@xmlTextNodeSearchResultsArray == 0 && @xmlElementNodeSearchResultsArray == 0) {
        print("WARNING: Subroutine setMetadataMultiple: Adding a new XML tag to the document that does not already exist in any form.\n");
    }

    if($behaviour =~ m/\AOVERWRITE\Z/) {
        print("INFO: Subroutine setMetadataMultiple: Modifying the XML document with OVERWRITE behaviour for the XML tag <$tagToFind>.\n");
        if(@xmlTextNodeSearchResultsArray == 0) {
            print("WARNING: Subroutine setMetadataMultiple: No <$tagToFind> XML tags with existing text found.\n");
            $nodeToInsertAfter = $xmlMetadata->lastChild();
        }
        else {
            # Remove all existing nodes after noting down the position of the first node
            $nodeToInsertAfter = $xmlTextNodeSearchResultsArray[0]->parentNode()->previousSibling();
            foreach my $node (@xmlTextNodeSearchResultsArray) {
                print("INFO: Subroutine setMetadataMultiple: Removing old <$tagToFind> node containing \'$node\' in accordance with OVERWRITE behaviour.\n");
                # As we are removing Text Nodes, need to get the Element Node parent to pass that to the removeChild function
                $xmlMetadata->removeChild($node->parentNode());
            }
        }

        # Search for XML tags without existing text:
        if(@xmlElementNodeSearchResultsArray == 0) {
            print("WARNING: Subroutine setMetadataMultiple: No <$tagToFind> XML tags without text found.\n");
            if(!defined($nodeToInsertAfter)) {
                $nodeToInsertAfter = $xmlMetadata->lastChild();
            }
        }
        else {            
            # Remove all existing nodes after noting down the position of the first node
            $nodeToInsertAfter = $xmlElementNodeSearchResultsArray[0]->previousSibling();
            foreach my $node (@xmlElementNodeSearchResultsArray) {
                print("INFO: Subroutine setMetadataMultiple: Removing unnecessary empty XML tag <$tagToFind>.\n");
                # As we are removing Text Nodes, need to get the Element Node parent to pass that to the removeChild function
                $xmlMetadata->removeChild($node);
            }
        }
    }

    if($behaviour =~ /\AAPPEND\Z/) {
        print("INFO: Subroutine setMetadataMultiple: Modifying the XML document with APPEND behaviour for the XML tag <$tagToFind>.\n");
        if(@xmlTextNodeSearchResultsArray != 0) {
            print("INFO: Subroutine setMetadataMultiple: Location to append new <$tagToFind> XML nodes after the existing ones discovered.\n");
            # There are existing Text Nodes, get the last one as a reference after which any new ones can be inserted
            $nodeToInsertAfter = $xmlTextNodeSearchResultsArray[-1]->parentNode();
        }
        else {
            print("INFO: Subroutine setMetadataMultiple: No <$tagToFind> XML tags with existing text found.\n");
        }

        # Now look for any empty Element Nodes and delete them after taking a reference of their position
        if(@xmlElementNodeSearchResultsArray != 0) {
            if(!defined($nodeToInsertAfter)) {
                $nodeToInsertAfter = $xmlElementNodeSearchResultsArray[0]->previousSibling();
            }
            foreach my $emptyNode (@xmlElementNodeSearchResultsArray) {
                $xmlMetadata->removeChild($emptyNode);
            }
        }
    }

    print("INFO: Subroutine setMetadataMultiple: Writing additional <$tagToFind> XML tags with the new text.\n");
    foreach my $text (@arrayOfTextToAdd) {
        my $newElement = $xmlDom->createElement($tagToFind);
        $newElement->appendText("$text");
        if(!defined($nodeToInsertAfter)) {
            # Deals with removing then replacing the first XML tag of the document
            $nodeToInsertAfter = $xmlMetadata->firstChild();
            $xmlMetadata->insertBefore($newElement, $nodeToInsertAfter);
            print("INFO: Subroutine setMetadataMultiple: Adding <$tagToFind> XML tag with the text: $text.\n");
        }
        else {
            $xmlMetadata->insertAfter($newElement, $nodeToInsertAfter);
            print("INFO: Subroutine setMetadataMultiple: Adding <$tagToFind> XML tag with the text: $text.\n");
        }
        $nodeToInsertAfter = $newElement;
    }

    ${$xmlDocumentReference} = $xmlDom->toString(1);
    return 1;
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: transferMetadata: transfer contents of a get_iplayer XML file
#  metadata tag to a kodi nfo file metadata tag (overwrite a single tag)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Description:
# Transfers the contents of a single XML tag from the input XML document to a 
# single XML tag in the output XML document. A list of tags can be searched for
# in the input XML document and the contents of the first XML tag found to 
# contain text will be transferred to the specified tag in the output XML document
#
# Arguments:
# $_[0] = Reference to a string containing an XML document to read from (input)
#         Usually the get_iplayer XML metadata file (input)
# $_[1] = Reference to a list of tags to read from the input XML document
#         The tags should be given in order of preference.
#         The first tag found to contain text will be used.
# $_[2] = Reference to a string containing an XML document to write to (output)
#         Usially the kodi nfo metadata file (output)
# $_[3] = THe name of the XML tag to write to in the output XML document
# Return Value:
# $tagText = Contents of the first tag found to contain text.
#            Or undef if none of the input XML tags contain any text.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub transferMetadata {
    if(@_ != 4) {
        print("ERROR: Subroutine transferMetadata: Wrong number of arguments supplied to subroutine. @_ supplied but the number should be 4.\n");
        return undef;
    }
    my ($iplayerXmlStringReference, $iplayerTagsReference, $kodiNfoStringReference, $kodiTag) = @_;

    print("INFO: Subroutine transferMetadata: Calling subroutine getMetadata...\n");
    my $text = getMetadata($iplayerXmlStringReference, @{$iplayerTagsReference});
    if(!defined $text) {
        print("ERROR: Subroutine transferMetadata: No XML tag with text found in the input XML document. Therefore nothing to write to the output XML document.\n");
        return undef;
    }

    print("INFO: Subroutine transferMetadata: Calling subroutine getMetadata...\n");
    if(setMetadataSingle($kodiNfoStringReference, $kodiTag, $text)) {
        print("SUCCESS: Subroutine transferMetadata: Successfully transferred the text \'$text\' from the input XML document to the <$kodiTag> XML tag in the output XML document.\n");
        return $text;
    }
    else {
        print("ERROR: Subroutine transferMetadata: Unable to transfer the text \'$text\' from the input XML document to the <$kodiTag> XML tag in the output XML document.\n");
        return undef;
    }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: downloadMetadataFile: download get_iplayer metadata file(s)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Description:
# Download one or more metadata files associated with a BBC iplayer programme
#
# Arguments:
# $_[0] = full path of directory to save file(s) to
# $_[1] = filename to use for saving files (no extension)
# $_[2] = media file PID
# $_[3] = reference to an array of file extension(s)/type(s), one or more of:
#         ('xml', 'srt', 'jpg', 'series.jpg', 'square.jpg', 'tracks.txt', 'cue', 'credits.txt')
# Return Value:
# @metadataFileFullPath = Full path(s) of the metadata file(s), if downloaded, or undef if none. 
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub downloadMetadataFile {
    my $savePath = $_[0];
    my $filenameNoPathNoExtension = $_[1];
    my $pid = $_[2];
    my $version = $_[3];
    my @fileExtensions = @{$_[4]};

    my @filesDownloaded;

    my $prettyMetadataFilesList = join(',', @fileExtensions);

    print("STATUS: Subroutine downloadMetadataFile: Attempting to download missing $prettyMetadataFilesList metadata files using get_iplayer.\n");

    if(!defined($savePath) || !defined($filenameNoPathNoExtension) || !defined($pid) || !defined($version)) {
        print("ERROR: One or more essential arguments to the subroutine donwloadMetadataFile are undefined\n");
        return undef;
    }
    if(@fileExtensions == 0) {
        print("ERROR: Subroutine downloadMetadataFile: Empty array of metadata files give as an argument to the subroutine downloadMetadataFile.\n");
        return undef;
    }
    if(!-d $savePath) {
        print("ERROR: Subroutine downloadMetadataFile: The argument savePath for the subroutine downloadMetadataFile is not a directory.\n");
        return undef;
    }
    # ensure no trailing slash
    $savePath =~ s/\/\Z//;

    my $get_iplayerMetadataOptions;
    my $filesToDownload = 0;
    # NB: each jpg - standard, series and square will be downloaded with the same filename and overwrite each other.
    # So series and square jpg files will be handled separately by their own get_iplayer commands whereas 
    # the other metadata file downloads can be grouped into a single get_iplayer command.
    foreach(@fileExtensions) {
        if($_ =~ m/\Axml\Z/) {
            $get_iplayerMetadataOptions .= '--metadata-only ';
            $filesToDownload++;
        }
        elsif($_ =~ m/\Asrt\Z/) {
            $get_iplayerMetadataOptions .= '--subtitles-only ';
            $filesToDownload++;
        }
        elsif($_ =~ m/\Ajpg\Z/) {
            $get_iplayerMetadataOptions .= '--thumbnail-only --thumbnail-size=1920 ';
            $filesToDownload++;
        }
        elsif($_ =~ m/\Aseries\.jpg\Z/) {
            # Special handling required to avoid overwriting other jpg files
            my $jpgOptions = '--thumbnail-series --thumbnail-size=1920';
            my $command = "$get_iplayer --get $jpgOptions --pid=$pid --versions=\"$version\" --output-tv=\"$savePath\" --output-radio=\"$savePath\" --file-prefix=\"$filenameNoPathNoExtension.series\"";
            print("STATUS: Subroutine downloadMetadataFile: Attempting to download missing metadata file(s) of type series.jpg to $savePath\n");
            print("STATUS: Subroutine downloadMetadataFile: Running command: $command\n");
            `$command`;
        }
        elsif($_ =~ m/\Asquare\.jpg\Z/) {
            # Special handling required to avoid overwriting other jpg files
            my $jpgOptions = '--thumbnail-square --thumbnail-size=1920';
            my $command = "$get_iplayer --get $jpgOptions --pid=$pid --versions=\"$version\" --output-tv=\"$savePath\" --output-radio=\"$savePath\" --file-prefix=\"$filenameNoPathNoExtension.square\"";
            print("STATUS: Subroutine downloadMetadataFile: Attempting to download missing metadata file(s) of type square.jpg to $savePath\n");
            print("STATUS: Subroutine downloadMetadataFile: Running command: $command\n");
            `$command`;
        }
        elsif($_ =~ m/\Atracks.txt\Z/) {
            $get_iplayerMetadataOptions .= '--tracklist-only ';
            $filesToDownload++;
        }
        elsif($_ =~ m/\Acue\Z/) {
            $get_iplayerMetadataOptions .= '--cusheet-only ';
            $filesToDownload++;
        }
        elsif($_ =~ m/\Acredits.txt\Z/) {
            $get_iplayerMetadataOptions .= '--credits-only ';
            $filesToDownload++;
        }
        else {
            print("ERROR: Subroutine downloadMetadataFile: Unrecognised metadata file type '$_'.\n");
            return undef;
        }
    }

    if($filesToDownload != 0) {
        my $prettyStringOfMetadataFiles = join(', ', @fileExtensions);
        my $command = "$get_iplayer --get $get_iplayerMetadataOptions --pid=$pid --versions=\"$version\" --output-tv=\"$savePath\" --output-radio=\"$savePath\" --file-prefix=\"$filenameNoPathNoExtension\"";
        print("STATUS: Subroutine downloadMetadataFile: Attempting to download missing metadata file(s) of type $prettyStringOfMetadataFiles to $savePath\n");
        print("STATUS: Subroutine downloadMetadataFile: Running command: $command\n");
        `$command`;
    }

    foreach(@fileExtensions) {
        my $fileExpectedLocation = $savePath . '/' . $filenameNoPathNoExtension . '.' . $_;
        if(-f $fileExpectedLocation) {
            push(@filesDownloaded, $fileExpectedLocation);
            print("STATUS: Subroutine downloadMetadataFile: Downloaded metadata file " . $filenameNoPathNoExtension . '.' . $_ . "\n");
        }
        else {
            print("WARNING: Subroutine downloadMetadataFile: Unable to download metadata file " . $filenameNoPathNoExtension . '.' . $_ . "\n");
        }
        return @filesDownloaded;
    }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: openMetadataFile: open get_iplayer XML metadata file
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Description:
# Open get_iplayer XML metadata file and minimally preprocess it
#
# Arguments:
# $_[0] = full path to get_iplayer XML metadata file to open
#
# Return Value:
# String containing the contents of the get get_iplayer XML metadata file
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub openMetadataFile {
    my $file = $_[0];
    if(-f $file) {
        print("INFO: Subroutine openMetadataFile: Attempting to open XML metadata file $file\n");
    }
    else {
        return undef;
    }
    my $xmlDocumentString;
    my $xmlFh;
    open($xmlFh, '<:encoding(UTF-8)', $file);
    while(my $line = <$xmlFh>) {
        # The get_iplayer generated XML includes an XML namespace (xmlns attribute) which complicates searching the file.
        # EITHER properly handle the XML namespace (instructions below) OR remove it before parsing the XML file
        # http://grantm.github.io/perl-libxml-by-example/namespaces.html
        # Decision: Remove the xmlns attribute as it is the only namespace in the file and its presence complicates
        # the construction of the XPATH expressions needed for searching the file.
        if($line =~ m/<program_meta_data/) {
            $line =~ s/ *xmlns=.*>/>/;
        }
        $xmlDocumentString .= $line;
    }
    if(length($xmlDocumentString) == 0 || !defined($xmlDocumentString)) {
        print("ERROR: Subroutine openMetadataFile: Unable to open XML metadata file or XML metadata file is empty: $file\n");
        return undef;
    }
    else {
        # Convert HTML character references e.g. &egrave; &Icirc; &#39; etc to unicode characters
        $xmlDocumentString = HTML::Entities::decode_entities($xmlDocumentString);
        # And convert back the ampersands that trip-up the XML parser
        $xmlDocumentString =~ s/&/&amp;/g;
        # TODO: Replace &amp; with ampersands once finished creating the nfo files?
        print("SUCCESS: Subroutine openMetadataFile: Returning contents of XML metadata file $file\n");
        return $xmlDocumentString;  
    }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# subroutine: print program usage information
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub printUsageInformation {
    print("A combination of the following command line arguments are required for the proper functioning of this program\n");
    # TODO: Write usage information message
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# MAIN PROGRAM STARTS HERE
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

if(@ARGV) {
    print("INFO: Processing command line arguments and checking for errors.\n");
    # Minimal processing of command line arguments
    while(my $currentArg = shift(@ARGV)) {
        if($currentArg =~ m/\A--convert\Z/) {
            $claConvert = 1;
        }
        elsif($currentArg =~ m/\A--revert\Z/) {
            $claRevert = 1;
        }
        elsif($currentArg =~ m/\A--recurse\Z/) {
            $claRecurse = 1;
        }
        # elsif($currentArg =~ m/\A--type/) {
        #     $currentArg = shift(@ARGV);
        #     if(defined($currentArg)) {
        #         if(length($currentArg) > 0) {
        #         push(@claType, $currentArg);
        #         }
        #         else {
        #             print("ERROR: --type command line argument requires a content type to be specified.\n");
        #             $claInvalid++;
        #         }
        #     }  
        # }
        elsif($currentArg =~ m/\A--source/) {
            $currentArg = shift(@ARGV);
            if(defined($currentArg)) {
                if(-e $currentArg) {
                    push(@claSource, File::Spec->rel2abs($currentArg));
                }
                else {
                    print("ERROR: --source command line argument requires a valid path to be specified. \'$currentArg\' is not a valid path.\n");
                    $claInvalid++;
                    if(defined($currentArg)) {
                        redo;
                    }
                }
            }
            else {
                print("ERROR: --source command line argument requires a valid path to be specified.\n");
                $claInvalid++;
            }
        }
        elsif($currentArg =~ m/\A--destination/) {
            $currentArg = shift(@ARGV);
            if(defined($currentArg)) {
                if(-e $currentArg) {
                    push(@claDestination, File::Spec->rel2abs($currentArg));
                }
                else {
                    print("ERROR: --destination command line argument requires a valid path to be specified. \'$currentArg\' is not a valid path.\n");
                    $claInvalid++;
                    if(defined($currentArg)) {
                        redo;
                    }
                }
            }
            else {
                print("ERROR: --destination command line argument requires a valid path to be specified.\n");
                $claInvalid++;
            }
        }
        elsif($currentArg =~ m/\A--get-iplayer\Z/) {
            $currentArg = shift(@ARGV);
            if(defined($currentArg)) {
                if(-e $currentArg) {
                    $claGetIplayer = File::Spec->rel2abs($currentArg);
                }
                else {
                    print("ERROR: --get-iplayer command line argument requires a valid path to be specified. \'$currentArg\' is not a valid path.\n");
                }
            }
            else {
                print("ERROR: --get-iplayer command line argument requires a valid path to be specified.\n");
            }
        }
        else {
            print("ERROR: Unrecognised command line argument $currentArg\n");
            $claInvalid++;
        }
    }

    # basic sanity checking on the collected command line arguments
    # cannot both convert and revert NOR neither convert nor revert
    if($claConvert == $claRevert) {
        print("ERROR: EITHER --convert OR --revert MUST be specified, NOT neither/both.\n");
        $claErrors++;
    }
    # check at least one path in $claSource array
    if(@claSource == 0) {
        print("ERROR: No --source argument supplied.\n");
        $claErrors++;
    }
    # check one path only in $claDestination array
    if(@claDestination == 0) {
        print("ERROR: No --destination argument supplied.\n");
        $claErrors++;
    }
    elsif(@claDestination != 1) {
        print("ERROR: More than one --destination argument supplied.\n");
        $claErrors++;
    }
    # # check only one type of content specified
    # if(@claType != 1) {
    #     print("ERROR: One media type must be specified with the --type command line argument.\n");
    #     $claErrors++;
    # }
    # else {
    #     if($claType[0] =~ m/\Afilm\Z/ || $claType[0] =~ m/\Amovie\Z/) {
    #         $claTypeFilm = 1;
    #     }
    #     elsif($claType[0] =~ m/\Atv\Z/ || $claType[0] =~ m/\ATV\Z/) {
    #         $claTypeTv = 1;
    #     }
    #     elsif($claType[0] =~ m/\Amusic\Z/) {
    #         $claTypeMusic = 1;
    #     }
    #     else {
    #         print("ERROR: Unknown content type \'$claType[0]\' supplied with --type= command line argument.\n");
    #         $claInvalid++;
    #     }
    # }

    # carry out initial processing of $claSource and $claDestination arrays
    foreach(@claSource) {
        my $path = $_;
        if(defined($path)) {
            if(-f $path) {
                if($path =~ m/\.mp4\Z/ || $path =~ m/\.m4a\Z/) {
                    push(@sourceMediaFiles, $path);
                }
                else {
                    print("ERROR: File specified with --source command line argument is not an mp4 video file nor an m4a audio file: $path\n");
                    $claErrors++;
                }
            }
            elsif(-d $path) {
                print("INFO: Found a directory as a --source command line argument: $path\n");
                push(@sourceDirs, $path);
            }
            else {
                print("ERROR: Path specified after --source command line argument is neither a valid source file nor directory: $path\n");
                $claErrors++;
            }
        }
    }
    if(defined($claDestination[0])) {
        if(-d $claDestination[0]) {
            $destinationDir = $claDestination[0];
            # ensure the consistent appearance of a trailing slash after the directory name
            $destinationDir =~ s/\/\Z//;
            $destinationDir .= '/';
        }
        else {
            print("ERROR: Path specified after --destination is not a valid directory: $claDestination[0]\n");
            $claErrors++;
        }
    }
    if(defined($claGetIplayer)) {
        if(-x $claGetIplayer) {
            print("INFO: Valid executable file found at path specified in command line arguments for get_iplayer.\n");
            $get_iplayer = $claGetIplayer;
        }
    }
    else{
        # Check get_iplayer is installed. NB: Does not check if 'whereis' is installed.
        my $whereisOutput = `whereis get_iplayer`;
        chomp($whereisOutput);
        (undef, $get_iplayer) = split(' ', $whereisOutput);
        if(defined($get_iplayer) && -x $get_iplayer) {
            # All good, path to get_iplayer found and it is executable
            print("INFO: Valid executable file found for get_iplayer found installed on this operating system.\n");
        }
        else {
            print("ERROR: get_iplayer is not installed on this computer.\n");
            print("       Download the latest version of get_iplayer from https://github.com/get-iplayer/get_iplayer\n");
            print("       and install it using the appropriate method https://github.com/get-iplayer/get_iplayer/wiki/installation\n");
            exit 1;
        }
    }

    # quit if invalid command line arguments OR errors in valid command line arguments detected
    if(($claInvalid != 0) || ($claErrors != 0)) {
        printUsageInformation();
        exit 1;
    }

    # Finished processing command line arguments.
    # A sensible combination of all required arguments should be proven by this point.
    # Now generate a complete list of mp4 files to work on and store the list in @sourceMediaFiles
    # print(Dumper(@sourceDirs));
    if(@sourceDirs) {
        foreach(@sourceDirs) {
            getMediaFiles($_);
        }
    }
    # print("STATUS: The following source files have been extracted from command line arguments:\n");
    # print(Dumper(@sourceMediaFiles));
    # print("STATUS: The following source directories have been extracted from command line arguments:\n");
    # print(Dumper(@sourceDirs));

    # One final sanity check before starting the conversion process.
    # If only source directories were specified by the -- source command line argument, then now is the first
    # time that it is possible to check if any valid mp4 files have been found to undergo the conversion process
    if(@sourceMediaFiles == 0) {
        print("ERROR: No valid media files (mp4 or m4a) have been found after processing the --source command line arguments.\n");
        exit 1;
    }  

    # Convert subdirectory names into full paths, destinationDir already has a trailing slash added
    $destinationDirFilm = $destinationDir . $destinationDirFilm;
    $destinationDirTv = $destinationDir . $destinationDirTv;
    $destinationDirMusic = $destinationDir . $destinationDirMusic;

    # Process each media file found
    foreach my $mediaFile (@sourceMediaFiles) {
        # Full path with the media file extension removed for constructing expected metadata filenames later
        my $mediaFileFullPathNoExtension = $mediaFile;
        $mediaFileFullPathNoExtension =~ s/\.mp4\Z//;
        $mediaFileFullPathNoExtension =~ s/\.m4a\Z//;
        my $mediaFilePid;
        my $mediaFileVersion;

        my $mediaFileSourceVolume;
        my $mediaFileSourceDirectory;
        my $mediaFileSourceFilename;
        ($mediaFileSourceVolume, $mediaFileSourceDirectory, $mediaFileSourceFilename) = File::Spec->splitpath("$mediaFile");
        my $mediaFileSourceFilenameNoExtension = $mediaFileSourceFilename;
        $mediaFileSourceFilenameNoExtension =~ s/\..*\Z//;
        my $mediaFileDestinationVolume;
        my $mediaFileDestinationDirectory;
        my $mediaFileDestinationFilename;

        print("STATUS: Processing media file: $mediaFileSourceFilename\n");

        # One of three values to identify which media subdirectory the media is moved to.
        # Determines filename construction pattern, which variant of kodi .nfo file is constructed for the file etc.
        my $mediaType;  # FILM, TV, RADIO

        # Carry out audit of associated metadata files
        # Check for the existance of the following
        my $metadataExistsXml = 0;          # - .xml
        my $metadataFileXml;
        my $iplayerMetadataFileXmlString;
        my $metadataExistsNfo = 0;          # - .nfo
        my $metadataFileNfo;
        my $metadataExistsSrt = 0;          # - .srt
        my $metadataFileSrt;
        my $metadataExistsJpg = 0;          # - .jpg
        my $metadataFileJpg;
        my $metadataExistsCreditsTxt = 0;   # - .credits.txt
        my $metadataFileCreditsTxt;
        my $metadataExistsCueSheet = 0;     # - .cue
        my $metadataFileCueSheet;
        my $metadataExistsTracksTxt = 0;    # - .tracks.txt
        my $metadataFileTracksTxt;

        my @metadataFilesToDownload;

        # check for the existance of various metadata files and download if absent.
        # Series and square thumbnail jpg files are NOT checked for here as they are special cases that will be handled later
        if(-f $mediaFileFullPathNoExtension . '.xml') {
            $metadataExistsXml = 1;
            $metadataFileXml = $mediaFileFullPathNoExtension . '.xml';
        }
        else {
            # No push: This is being dealt with specially as a matter of urgency and separate from the other metadata files
            # push(@metadataFilesToDownload, 'xml');
        }
        if(-f $mediaFileFullPathNoExtension . '.nfo') {
            $metadataExistsNfo = 1;
            $metadataFileNfo = $mediaFileFullPathNoExtension . '.nfo';
        }
        else {
            # No push: get_iplayer generated nfo files are obsolete, existing ones are inaccurate, will generate new ones manually.
            # Assume any existing ones are old, and any new ones can be regenerated from XML metadata file information,
        }
        if(-f $mediaFileFullPathNoExtension . '.srt') {
            $metadataExistsSrt = 1;
            $metadataFileSrt = $mediaFileFullPathNoExtension . '.srt';
        }
        else {
            push(@metadataFilesToDownload, 'srt');
        }
        if(-f $mediaFileFullPathNoExtension . '.jpg') {
            $metadataExistsJpg = 1;
            $metadataFileJpg = $mediaFileFullPathNoExtension . '.jpg';
        }
        else {
            push(@metadataFilesToDownload, 'jpg');
        }
        if(-f $mediaFileFullPathNoExtension . '.credits.txt') {
            $metadataExistsCreditsTxt = 1;
            $metadataFileCreditsTxt = $mediaFileFullPathNoExtension . '.credits.txt';
        }
        else {
            push(@metadataFilesToDownload, 'credits.txt');
        }
        if(-f $mediaFileFullPathNoExtension . '.cue') {
            $metadataExistsCueSheet = 1;
            $metadataFileCueSheet = $mediaFileFullPathNoExtension . '.cue';
        }
        else {
            push(@metadataFilesToDownload, 'cue');
        }
        if(-f $mediaFileFullPathNoExtension . '.tracks.txt') {
            $metadataExistsTracksTxt = 1;
            $metadataFileTracksTxt = $mediaFileFullPathNoExtension . '.tracks.txt';
        }
        else {
            push(@metadataFilesToDownload, 'tracks.txt');
        }

        # Attempt to download missing metadata files to the SOURCE directory, particularly the .xml metadata file if it was not found during the checks for associated files
        # Download of missing XML metadata file will be done ONLY IF the programme PID can be extracted from the filename...
        my $justDownloadedFreshMetadata = 0;
        if(!$metadataExistsXml) {
            print("WARNING: No associated XML metadata file found.\n");
            # Attempt to extract programme PID and version from the filename
            $mediaFilePid = $mediaFileSourceFilename;
            $mediaFileVersion = $mediaFileSourceFilename;
            $mediaFilePid =~ s/.+[_ ]{1}([a-zA-Z0-9]{8})[_ ]{1}[a-zA-Z0-9]+\.m[a-zA-A1-9]{2}\Z/$1/;
            $mediaFileVersion =~ s/.+[_ ]{1}[a-zA-Z0-9]{8}[_ ]{1}([a-zA-Z0-9]+)\.m[a-zA-A1-9]{2}\Z/$1/;

            # check mediaFilePid is a an 8 character PID and that it has not been mistaken for the most common 8 character long programme version 'original'
            if(length($mediaFilePid) == 8 && $mediaFilePid !~ /\Aoriginal\Z/) {
                print("STATUS: Extracted possible PID from filename: $mediaFilePid\n");              
                print("STATUS: Attempting to download of missing XML metadata file.\n");
                my @listOfMetadataFilesToDownload = ('xml');
                my ($candidateXmlFile) = downloadMetadataFile($mediaFileSourceDirectory, $mediaFileSourceFilenameNoExtension, $mediaFilePid, $mediaFileVersion, \@listOfMetadataFilesToDownload);

                # Check if the XML metadata file was downloaded by get_iplayer
                if(-f $candidateXmlFile) {
                    $metadataExistsXml = 1;
                    $justDownloadedFreshMetadata = 1;
                    $metadataFileXml = $candidateXmlFile;
                    print("STATUS: Confirmed download of missing XML metadata file.\n");
                }
                else {
                    print("WARNING: Unable to download missing XML metadata file.\n");
                    # TODO: Decide whether to continue to process files with missing metadata.
                    # Do not process further? Process but log?
                }
            }
            else {
                print("WARNING: Unable to determine PID and hence unable to download missing XML metadata file.\n");
            }   
        }

        # Load .xml metadata file if it exists, later attempt reconstruction if it does not.
        if($metadataExistsXml) {
            print("STATUS: Starting advanced parsing of programme information using associated XML metadata file...\n");
            if(!defined($iplayerMetadataFileXmlString = openMetadataFile($metadataFileXml))) {
                print("ERROR: Unable to open get_iplayer XML metadata file $metadataFileXml\n");
                #TODO: Decide what action to take upon this error
            }
            # Older get_iplayer XML files do not include all the tags that exist in newer get_iplayer XML files
            # check for presence of newer XML tags, choosing here to check for two of the more useful newer tags 
            # <sesort>, <firstbcastyear> but throwing away the results as not necessarily needed yet.
            my $iplayerXmlNewerType = 0;
            if(defined(getMetadata(\$iplayerMetadataFileXmlString, 'firstbcastyear')) || defined(getMetadata($iplayerMetadataFileXmlString, 'sesort'))) {
                $iplayerXmlNewerType = 1;
            }

            $mediaFilePid = getMetadata(\$iplayerMetadataFileXmlString, 'pid');
            if(length($mediaFilePid) == 8) {
                print("STATUS: Extracted programme PID from XML metadata file: $mediaFilePid\n");
            }
            else {
                print("ERROR: Unable to extract programme PID from XML metadata file: $mediaFilePid\n");
            }

            $mediaFileVersion = getMetadata(\$iplayerMetadataFileXmlString, 'version');
            if(defined($mediaFileVersion)) {
                print("STATUS: Extracted programme version from XML metadata file: $mediaFileVersion\n");
            }
            else {
                print("ERROR: Unable to extract programme version from XML metadata file: $mediaFileVersion\n");
            }

            my $metadataFileXmlOld = "$metadataFileXml.old";
            if($iplayerXmlNewerType == 0 && $justDownloadedFreshMetadata == 0) {
                # redownload the XML file after backing up the old one
                print("WARNING: Older XML metadata file found that is missing newer metadata tags, attempting to download a newer version.\n");           
                move($metadataFileXml, $metadataFileXmlOld);
                my @metadataFilesToDownload = ('xml');
                ($metadataFileXml) = downloadMetadataFile($mediaFileSourceDirectory, $mediaFileSourceFilenameNoExtension, $mediaFilePid, $mediaFileVersion, \@metadataFilesToDownload);
                if(defined($metadataFileXml) && -f $metadataFileXml) {
                    if(defined($iplayerMetadataFileXmlString = openMetadataFile($metadataFileXml))) {
                        print("SUCCESS: Successfully downloaded a newer version of the get_iplayer XML metadata file.\n");
                        print("INFO: Checking the newer version of the get_iplayer XML metadata file for the latest XML tags.\n");
                        if(defined(getMetadata(\$iplayerMetadataFileXmlString, 'firstbcastyear')) || defined(getMetadata($iplayerMetadataFileXmlString, 'sesort'))) {
                            $iplayerXmlNewerType = 1;
                        }
                        if($iplayerXmlNewerType == 1) {
                            print("STATUS: Successfully the newer version of the XML metadata file contains the latest XML tags.\n");
                        }
                        else {
                            print("WARNING: Downloaded a newer version of the XML metadata file but it does not appear to contain newer tags\n");
                        }
                    }
                }
                else {
                    print("WARNING: Unable to download a newer version of the XML metadata file.\n");
                    move($metadataFileXmlOld, $metadataFileXml);
                }
            }
            
            # Identify whether the media file is a film, tv programme or radio/music/podcast
            # Radio being the only media type with an m4a file extension AND/or a <type>radio</type> tag.
            # Films usually, but not always, have the string 'Films' in the <categories>...</categories> tag.
            # TV can only be categorised as 
            my $iplayerTagType = getMetadata(\$iplayerMetadataFileXmlString, 'type');
            my $iplayerTagCategories = getMetadata(\$iplayerMetadataFileXmlString, 'categories');

            print("STATUS: Attempting to classify media file.\n");
            if($mediaFileSourceFilename =~ m/\.m4a\Z/ && $iplayerTagType =~ m/[Rr]adio/) {
                $mediaType = 'RADIO';
                print("STATUS: Media file classified as: RADIO.\n");
            }
            elsif($mediaFileSourceFilename =~ m/\.mp4\Z/ && $iplayerTagCategories =~ m/[Ff]ilm/) {
                $mediaType = 'FILM';
                print("STATUS: Media file classified as: FILM.\n");
            }
            elsif($mediaFileSourceFilename =~ m/\.mp4\Z/) {
                $mediaType = 'TV';
                print("STATUS: Media file classified as: TV.\n");
            }
            else {
                $mediaType = 'UNKNOWN';
                print("ERROR: Media file with tag \'$iplayerTagType\' could not be classified as either FILM, TV or RADIO: $mediaFile\n");
                # TODO: Log it. 
                next;
            }

            # Create a new kodi-compatible .nfo metadata file for the media file
            # Different .nfo templates are used depending on the media type; RADIO, FILM or TV
            # This is a simple manual translation of get_iplayer XML tags into their kodi equivalents.
            if($mediaType =~ m/\AFILM\Z/) {
                my $newFilenameName;
                my $newFilenameYear;
                print("STATUS: Using FILM type rules to process the media file $mediaFileSourceFilename\n");
                print("STATUS: Creating <movie> type Kodi compatible nfo metadata file.\n");
                # load the kodi nfo template
                my $nfofh;
                my $kodiNfoFilmString;
                my $iplayerXmlNewerType = 0;
                open($nfofh, '<:encoding(UTF-8)', "$programDirectoryFullPath/kodi_metadata_templates/kodiNfoTemplateFilm.nfo");
                while(my $line = <$nfofh>) {
                    $kodiNfoFilmString .= $line;
                }

                # Map get_iplayer <title>, <nameshort>, <name>, <longname> or <brand> to kodi <title>
                my @iplayerNameTagCandidates = ('title', 'nameshort', 'name', 'longname', 'brand');
                $newFilenameName = transferMetadata(\$iplayerMetadataFileXmlString, \@iplayerNameTagCandidates, \$kodiNfoFilmString, 'title');

                # Map get_iplayer <descshort>, <desc> or <descmedium> to kodi <outline>
                my @iplayerShortDescriptionTagCandidates = ('descshort', 'desc', 'descmedium');
                transferMetadata(\$iplayerMetadataFileXmlString, \@iplayerShortDescriptionTagCandidates, \$kodiNfoFilmString, 'outline');

                # Map get_iplayer <desclong>, <descmedium>, <desc> or <descshort> to kodi <plot>
                my @iplayerLongDescriptionTagCandidates = ('desclong', 'descmedium', 'desc', 'descshort');
                transferMetadata(\$iplayerMetadataFileXmlString, \@iplayerLongDescriptionTagCandidates, \$kodiNfoFilmString, 'plot');

                # Map get_iplayer <duration>, <durations> to kodi <runtime>
                my @iplayerDurationTagCandidates = ('duration', 'durations');
                transferMetadata(\$iplayerMetadataFileXmlString, \@iplayerDurationTagCandidates, \$kodiNfoFilmString, 'runtime');

                # Map the YEAR of get_iplayer <firstbcastyear> to kodi <premiered>
                # Although this is almost always wrong for films for it choses the TV broadcast date rather than the cinema release date.
                my @iplayerFirstBroadcastTagCandidates = ('firstbcastyear');
                my $firstBroadcastYear = transferMetadata(\$iplayerMetadataFileXmlString, \@iplayerFirstBroadcastTagCandidates, \$kodiNfoFilmString, 'premiered');

                # All easily and directly transferrable metadata now transferred.
                
                # If no get_iplayer <firstbcastyear> tag found then there are two choices:
                # EITHER search for <firstbcast>, <firstbcastdate> and extract the year from the full date.
                # OR attempt to download the iplayer programme webpage and extract the "firstBroadcast" information from there
                # Tag samples:
                # <firstbcast>2009-09-18T21:50:00+01:00</firstbcast>
	            # <firstbcastdate>2009-09-18</firstbcastdate>
                if(!defined($firstBroadcastYear)) {
                    print("No <firstbcastyear> tag found, searching for <firstbcast>, <firstbcastdate> tags instead");
                    @iplayerFirstBroadcastTagCandidates = ('firstbcast', 'firstbcastdate');
                    $firstBroadcastYear = getMetadata(\$iplayerMetadataFileXmlString, @iplayerFirstBroadcastTagCandidates);
                    $firstBroadcastYear =~ s/\A([12][0-9]{3})-/$1/;
                    if(1900 < $firstBroadcastYear && $firstBroadcastYear < 2050) {
                        $newFilenameYear = $firstBroadcastYear;
                        setMetadataSingle(\$kodiNfoFilmString, 'premiered', $newFilenameYear);
                    }
                }

                # Experimental, go to the bbc website, download the program webpage and extract "firstBroadcast" information.
                my $webifiedProgrammeName = lc($newFilenameName);
                $webifiedProgrammeName =~ s/\s/-/g;
                # TODO: Check if $webifiedProgrammeName is needed on the end of the URL (whether LWP::Simple->get() can handle 301 redirection)
                my $programmeUrl = "https://www.bbc.co.uk/iplayer/episode/$mediaFilePid";#/$webifiedProgrammeName";
                print("STATUS: Attempting to download programme's iplayer webpage $programmeUrl\n");
                my $webpage = get($programmeUrl);
                if(defined($webpage)) {
                    
                    # #Experimental alternative
                    # my $experimentalYear;
                    # foreach(split('\n', $webpage)) {
                    #     if(defined($_)){
                    #         $_ =~ s/"firstBroadcast":"([1-9]{4})"/$1/;
                    #         $experimentalYear = $1;
                    #         if(defined($experimentalYear)) {
                    #             if($experimentalYear > 1900 && $experimentalYear < 2100) {
                    #                 print("Experimental year = $experimentalYear\n");
                    #                 last;
                    #             }
                    #         }
                    #     }
                    # }

                    # # Alternate experimental alternative. Does not work with strings that have code points over 0xFF.
                    # my $experimentalYear;
                    # my $strfh;
                    # open($strfh, '<:encoding(UTF-8)', \$webpage);
                    # while(my $webline = readline($strfh)) {
                    #     if($webline =~ m/"firstBroadcast":"([1-9]{4})"/) {
                    #         $experimentalYear = $1;
                    #         print("Experimental year = $experimentalYear\n");
                    #     }
                    # }
                    # close($strfh);
                    
                    # TODO: Searching the whole file in a single string is probably quite inefficient
                    # It works but should it be changed? It's very short and neat compared to the alternative (see above)
                    # NB: my $parsedYear =~ s/"firstBroadcast":"([1-9]{4})"/$1/sgc; DOES NOT WORK
                    my $parsedYear;
                    if($webpage =~ m/"firstBroadcast":"([1-9]{4})"/s) {
                        $parsedYear = $1;
                    }
                    else {
                        print("STATUS: Could not find a more accurate year of first broadcast on the programme's iplayer webpage.\n");
                    }
                    if(length($parsedYear) == 4) {
                        print("SUCCESS: Found year of first broadcast from programme's iplayer webpage: $parsedYear\n");
                        $newFilenameYear = $parsedYear;
                        setMetadataSingle(\$kodiNfoFilmString, 'premiered', $newFilenameYear);
                    }
                }
                else{
                    print("WARNING: Unable to download the programme's iplayer webpage.\n");
                }

                # Testing setMetadataMultiple subroutine
                my @tagTestList = ('foo', 'bar', 'foobar', 'barfoo');
                setMetadataMultiple(\$kodiNfoFilmString, 'premiered', \@tagTestList, 'OVERWRITE');

                # Now handle the transfer of get_iplayer's <categories> and <category> (multiple categories to one tag) to kodi's <genre> (one cagegory per multiple tags)
                # get_iplayer will mix actors with categories in the <categories> tag. Need to produce a list of acceptable categories to match against...
                # Those strings appearing in <categories> could be considered actors and moved to the <actor> tag

                # Print poplulated kodi nfo metadata string and a final newline
                print("$kodiNfoFilmString" . "\n");

            }
            elsif($mediaType =~ m/\ATV\Z/) {
                my $mediaFileNfoString = $kodiNfoTemplateFilm;
                # Map get_iplayer ___ to kodi ___
                # Map get_iplayer ___ to kodi ___
                # Map get_iplayer ___ to kodi ___
                # Map get_iplayer ___ to kodi ___
                # Map get_iplayer ___ to kodi ___
            }
            elsif($mediaType =~ m/\ARADIO\Z/) {
                # Kodi has no obvious support for associating .nfo files with individual music tracks
                # The TV programme or music video nfo template could be used as they contain relevant tags to radio programmes,
                # but would Kodi even look for them?
            }
 
        }
        else {
            print("Starting basic parsing of programme information using filename only...\n");
            # Identify whether the media file is a film, tv programme or radio/music/podcast
            # Can only make the determination based upon file extension. mp4 or m4a therefore TV or RADIO only
            # TODO: Investigate metadata encoded within the media files using Atomic Parsley?
            if($mediaFileSourceFilename =~ m/\.m4a\Z/) {
                $mediaType = 'RADIO';
                # print("Media file classified as: RADIO\n");
            }
            elsif($mediaFileSourceFilename =~ m/\.mp4\Z/) {
                $mediaType = 'TV';
                # print("Media file classified as: TV\n");
            }
            else {
                $mediaType = 'UNKNOWN';
                print("ERROR: Media file could not be classified as either RADIO, FILM or TV\n");
                # TODO: Log it. 
                next;
            }
            # TODO: Reconstruct programme name, series number, episode number, episode name, pid and version from the filename
        }
        # print("\n");

    } 
}
else {
    printUsageInformation();
    exit 1;
}