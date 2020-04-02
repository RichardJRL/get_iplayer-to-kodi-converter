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
my $separator = '_';    # Kodi allows spces, periods or underscores as separators for words in the directory and file names. Default is underscore.

# variables to hold files and directories to work on
my @sourceDirs;         # Only the valid source directories harvested from the command line arguments
my @completeListOfDirs; # Entire list of all source directories found when getMediaFiles called (used for debug purposes only)
my @sourceMediaFiles;
my $destinationDir;
my $destinationSubdirFilm = 'films';  # do not include trailing slash
my $destinationSubdirTv = 'tv';       # not include trailing slash
my $destinationSubdirMusic = 'radio'; # not include trailing slash


# other major variables
my $get_iplayer;           # full path to the get_iplayer program 
my $programDirectoryFullPath = File::Spec->rel2abs(dirname(__FILE__));
my $categoryDir .= '/categories/';
my @masterCategoryList;

# function references:
my $transfer = \&File::Copy::copy;

# Kodi template nfo metadata files loaded into strings as required
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
# $_[1] = An array of XML tag names to search for
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
# On failure, returns a boolean false (0), on success, returns a boolean true (1)
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
# On failure, returns a boolean false (0), on success, returns a boolean true (1)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
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
#  metadata tag to a Kodi nfo file metadata tag (overwrite a single tag)
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
#         Usially the Kodi nfo metadata file (output)
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
# subroutine: transferMetadataCategories: transfer iplayer categories to
# Kodi genres via filtering categories against an approved list
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Description:
# First this extracts the contents of the XML <category> and <categories> tags 
# from an iplayer XML metadata file.
# Then it checks if any of the extracted categories match against a pre-compiled
# list of approved categories.
# Finally, it writes the extracted categories which were on the approved list
# to the <genre> XML tag of a Kodi nfo metadata file. Kodi only allows a single
# category per <genre> tag, so multiple <genre> tags may be written. 
# Behavour is to APPEND to the set of Kodi <genre> tags. (Add new tags)
#
# Arguments:
# $_[0] = Reference to a string containing an XML document to read from (input)
#         Usually the get_iplayer XML metadata file (input)
# $_[2] = Reference to a string containing an XML document to write to (output)
#         Usially the Kodi nfo metadata file (output)
# Return Value:
# On failure, returns a boolean false (0), on success, returns a boolean true (1)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub transferMetadataCategories {
    my $inputStringReference = $_[0];
    my $outputStringReference = $_[1];
    print("INFO: Subroutine transferMetadataCategories: Parsing programme categories from the iplayer XML metadata file and matching them against list of approved programme categories.\n");
    my @approvedCategories;
    my @catTagNames = ('category', 'categories');
    my $candidateCategoryString;
    foreach(@catTagNames) {
        print("INFO: Subroutine transferMetadataCategories: Querying the iplayer XML metadata file's <$_> XML tag contents for approved programme categories.\n");
        $candidateCategoryString = getMetadata($inputStringReference, $_);
        if(defined($candidateCategoryString)) {
            my @candidateCategories = split(',', $candidateCategoryString);
            foreach my $candidateCat (@candidateCategories) {
                print("INFO: Subroutine transferMetadataCategories: Inspecting the candidate category: $candidateCat\n");
                my $catAlreadyInList = 0;
                my $catOnApprovedList = 0;
                foreach my $approvedCat (@approvedCategories) {
                    if($approvedCat =~ m/\A$candidateCat\Z/) {
                        $catAlreadyInList++;
                        print("INFO: Subroutine transferMetadataCategories: Candidate category $candidateCat already in the list of approved categories to be transferred.\n");
                        last;
                    }
                }
                foreach my $approvedCat (@masterCategoryList) {
                    if($approvedCat =~ m/\A$candidateCat\Z/) {
                        $catOnApprovedList++;
                        print("INFO: Subroutine transferMetadataCategories: Category \'$candidateCat\' is on the approved list of programme categories.\n");
                        last;
                    }
                }
                if($catAlreadyInList == 0 && $catOnApprovedList == 1) {
                    push(@approvedCategories, $candidateCat);
                    print("SUCCESS: Subroutine transferMetadataCategories: Added category \'$candidateCat\' to the list of approved categories to be transferred.\n");
                }
                elsif($catOnApprovedList == 0) {
                    print("WARNING: Subroutine transferMetadataCategories: Category \'$candidateCat\' is not on the approved list of programme categories.\n");
                }                
            }
        }
    }
    my $prettyApprovedCategoriesString = join(', ', @approvedCategories);
    $prettyApprovedCategoriesString =~ s/, \Z//;
    if(@approvedCategories >= 1) {
        # This is the "successful" return path, but could still return failure if an error occurs in setMetadataMultiple
        print("INFO: Subroutine transferMetadataCategories: The following approved programme categories will be transferred to the Kodi NFO metadata file: $prettyApprovedCategoriesString\n.");
        return(setMetadataMultiple($outputStringReference, 'genre', \@approvedCategories , 'APPEND'));
    }
    else {
        print("WARNING: Subroutine transferMetadataCategories: Zero approved programme categories found for transfer to the Kodi NFO metadata file.\n.");
        return 1;
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
# $_[3] = media file version
# $_[4] = an array of file extension(s)/type(s), one or more of:
#         ('xml', 'srt', 'jpg', 'series.jpg', 'square.jpg', 'tracks.txt', 'cue', 'credits.txt')
# Return Value:
# @metadataFileFullPath = Full path(s) of the metadata file(s), if downloaded, or undef if none. 
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub downloadMetadataFile {
    my ($savePath, $filenameNoPathNoExtension, $pid, $version, @fileExtensions) = @_;

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
        elsif($currentArg =~ m/\A--separator\Z/) {
            $currentArg = shift(@ARGV);
            if(defined($currentArg)) {
                if($currentArg =~ m/\A \Z/ || m/\A\.\Z/ || m/\A_\Z/) {
                    $separator = $currentArg;
                }
                else {
                    print("ERROR: --separator command line argument requires a valid character to be specified. Valid characters are a single space ' ', period '.', or underscore '_'.\n");
                }
            }
            else {
                print("ERROR: --separator command line argument requires a valid character to be specified. Valid characters are a single space ' ', period '.', or underscore '_'.\n");
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
            if($destinationSubdirFilm !~ m/\/\Z/) {
                $destinationSubdirFilm .= '/';
            }
            if($destinationSubdirTv !~ m/\/\Z/) {
                $destinationSubdirTv .= '/';
            }
            if($destinationSubdirMusic !~ m/\/\Z/) {
                $destinationSubdirMusic .= '/';
            }
            
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

    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # Finished processing command line arguments - starting proper work!
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
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

    $categoryDir = $programDirectoryFullPath . $categoryDir;
    $categoryDir =~ s/\/\//\//;
    my $catdirfh;
    opendir($catdirfh, $categoryDir);
    while(my $path = readdir($catdirfh)) {
        if($path =~ m/\A\.{1,2}\Z/) {    # ignore dotted current (.) and parent (..) dirs
            next;
        }
        elsif($path =~ m/\.unique\Z/) {
            $path = $categoryDir . $path;
            print("INFO: Path is $path\n");
            my $fh;
            open($fh, '<:encoding(UTF-8)', $path);
            while(my $line = <$fh>) {
                my $catAlreadyInList = 0;
                foreach my $cat (@masterCategoryList) {
                    if($cat =~ m/\A$line\Z/) {
                        $catAlreadyInList++;
                    }
                }
                if($catAlreadyInList == 0) {
                    push(@masterCategoryList, $line);
                }
            }
            close($fh);
        }
    }
    closedir($catdirfh);
    @masterCategoryList = sort(@masterCategoryList);
    foreach(@masterCategoryList) {
        print("$_");
    }



    # Process each media file found
    foreach my $mediaFile (@sourceMediaFiles) {
        # Full path with the media file extension removed for constructing expected metadata filenames later
        my $mediaFileFullPathNoExtension = $mediaFile;
        $mediaFileFullPathNoExtension =~ s/\.mp4\Z//;
        $mediaFileFullPathNoExtension =~ s/\.m4a\Z//;
        my $mediaFilePid;
        my $mediaFileVersion;
        my $mediaFileThumbnail;

        my $mediaFileSourceVolume;
        my $mediaFileSourceDirectory;
        my $mediaFileSourceFilename;
        
        ($mediaFileSourceVolume, $mediaFileSourceDirectory, $mediaFileSourceFilename) = File::Spec->splitpath("$mediaFile");
        my $mediaFileSourceFilenameNoExtension = $mediaFileSourceFilename;
        $mediaFileSourceFilenameNoExtension =~ s/\..*\Z//;
        
        my $mediaFileDestinationVolume;     # Volume only. TODO: Not fully implemented yet (but Windows only)
        my $mediaFileDestinationDirectory;  # Full path
        my $mediaFileDestinationFilename;   # Filename only
        my $mediaFileSeriesAtworkDirectory; # Full path. For TV and Radio
        
        ($mediaFileDestinationVolume, $mediaFileDestinationDirectory) = File::Spec->splitpath($destinationDir);

        my $iplayerXmlString;
        my $kodiNfoString;
        my $nfofh;

        # Variables for construction file and subdirectory names in the destination directory
        my $newNameShowName;            # For All
        my $newNameYear;                # For Film, TV and Radio
        my $newNameSeriesName;          # For TV and Radio
        my $newNameSeriesNumber;        # For TV and Radio
        my $newNameEpisodeName;         # For TV and Radio
        my $newNameSeriesEpisodeCode;   # For TV and Radio
        my $newFilenameComplete;        # For All (concatenation of all required newFilename... variables)
        
        
        # Convert subdirectory names into full paths, destinationDir already has a trailing slash added
        # $destinationDirFilm = "$destinationDir" . "$destinationDirFilm";
        # $destinationDirTv = $destinationDir . $destinationDirTv;
        # $destinationDirMusic = $destinationDir . $destinationDirMusic;

        print("STATUS: Processing media file: $mediaFileSourceFilename\n");

        # One of three values to identify which media subdirectory the media is moved to.
        # Determines filename construction pattern, which variant of Kodi .nfo file is constructed for the file etc.
        my $mediaType;  # FILM, TV, RADIO

        # Carry out audit of associated metadata files
        # Check for the existance of the following
        my $metadataFileXml;

        # check for the existance of various metadata files and download if absent.
        if(-f $mediaFileFullPathNoExtension . '.xml') {
            $metadataFileXml = $mediaFileFullPathNoExtension . '.xml';
        }

        # Attempt to download missing metadata files to the SOURCE directory, particularly the .xml metadata file if it was not found during the checks for associated files
        # Download of missing XML metadata file will be done ONLY IF the programme PID can be extracted from the filename...
        my $justDownloadedFreshXmlMetadata = 0;
        if(!-f $metadataFileXml) {
            print("WARNING: No associated XML metadata file found.\n");
            # Attempt to extract programme PID and version from the filename
            $mediaFilePid = $mediaFileSourceFilename;
            $mediaFileVersion = $mediaFileSourceFilename;
            $mediaFilePid =~ s/.+[_ ]{1}([a-zA-Z0-9]{8})[_ ]{1}[a-zA-Z0-9]+\.m[a-zA-A1-9]{2}\Z/$1/;
            $mediaFileVersion =~ s/.+[_ ]{1}[a-zA-Z0-9]{8}[_ ]{1}([a-zA-Z0-9]+)\.m[a-zA-A1-9]{2}\Z/$1/;

            # check mediaFilePid is a an 8 character PID and that it has not been mistaken for the most common 8 character long programme version 'original'
            if(length($mediaFilePid) == 8 && $mediaFilePid !~ m/\Aoriginal\Z/) {
                print("STATUS: Extracted possible PID from filename: $mediaFilePid\n");              
                print("STATUS: Attempting to download of missing XML metadata file.\n");
                my ($candidateXmlFile) = downloadMetadataFile($mediaFileSourceDirectory, $mediaFileSourceFilenameNoExtension, $mediaFilePid, $mediaFileVersion, 'xml');

                # Check if the XML metadata file was downloaded by get_iplayer
                if(-f $candidateXmlFile) {
                    $justDownloadedFreshXmlMetadata = 1;
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
        if(-f $metadataFileXml) {
            print("STATUS: Starting advanced parsing of programme information using associated XML metadata file...\n");
            if(!defined($iplayerXmlString = openMetadataFile($metadataFileXml))) {
                print("ERROR: Unable to open get_iplayer XML metadata file $metadataFileXml\n");
                #TODO: Decide what action to take upon this error
            }
            # Older get_iplayer XML files do not include all the tags that exist in newer get_iplayer XML files
            # check for presence of newer XML tags, choosing here to check for two of the more useful newer tags 
            # <sesort>, <firstbcastyear> but throwing away the results as not necessarily needed yet.
            my $iplayerXmlNewerType = 0;
            if(defined(getMetadata(\$iplayerXmlString, 'firstbcastyear')) || defined(getMetadata($iplayerXmlString, 'sesort'))) {
                $iplayerXmlNewerType = 1;
            }

            $mediaFilePid = getMetadata(\$iplayerXmlString, 'pid');
            if(length($mediaFilePid) == 8) {
                print("STATUS: Extracted programme PID from XML metadata file: $mediaFilePid\n");
            }
            else {
                print("ERROR: Unable to extract programme PID from XML metadata file: $mediaFilePid\n");
            }

            $mediaFileVersion = getMetadata(\$iplayerXmlString, 'version');
            if(defined($mediaFileVersion)) {
                print("STATUS: Extracted programme version from XML metadata file: $mediaFileVersion\n");
            }
            else {
                print("ERROR: Unable to extract programme version from XML metadata file: $mediaFileVersion\n");
            }
            # Thumbnail URL contents needed later for establishing size of already-downloaded thumbnail
            # NB: $mediaFileThumbnail MUST be defined BEFORE the get_iplayer XML metadata is re-downloaded as that changes the <thumbnail> URL information from what was originally downloaded.

            $mediaFileThumbnail = getMetadata(\$iplayerXmlString, 'thumbnail');
            if(defined($mediaFileThumbnail)) {
                print("STATUS: Extracted programme thumbnail URL from XML metadata file: $mediaFileThumbnail\n");
            }
            else {
                print("ERROR: Unable to extract programme thumbnail URL from XML metadata file: $mediaFileThumbnail\n");
            }

            my $metadataFileXmlOld = "$metadataFileXml.old";
            if($iplayerXmlNewerType == 0 && $justDownloadedFreshXmlMetadata == 0) {
                # redownload the XML file after backing up the old one
                print("WARNING: Older XML metadata file found that is missing newer metadata tags, attempting to download a newer version.\n");           
                move($metadataFileXml, $metadataFileXmlOld);
                ($metadataFileXml) = downloadMetadataFile($mediaFileSourceDirectory, $mediaFileSourceFilenameNoExtension, $mediaFilePid, $mediaFileVersion, 'xml');
                if(defined($metadataFileXml) && -f $metadataFileXml) {
                    if(defined($iplayerXmlString = openMetadataFile($metadataFileXml))) {
                        print("SUCCESS: Successfully downloaded a newer version of the get_iplayer XML metadata file.\n");
                        print("INFO: Checking the newer version of the get_iplayer XML metadata file for the latest XML tags.\n");
                        if(defined(getMetadata(\$iplayerXmlString, 'firstbcastyear')) || defined(getMetadata($iplayerXmlString, 'sesort'))) {
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
            my $iplayerTagType = getMetadata(\$iplayerXmlString, 'type');
            my $iplayerTagCategories = getMetadata(\$iplayerXmlString, 'categories');

            print("STATUS: Attempting to classify media file.\n");
            if($mediaFileSourceFilename =~ m/\.m4a\Z/ && $iplayerTagType =~ m/[Rr]adio/) {
                $mediaType = 'RADIO';
                print("STATUS: Media file classified as: RADIO.\n");
                # TODO: Add opening of kodiNfoTemplateTvEpisode.nfo here, as per $mediaType TV. Because Radio has more in common with TV programmes than Music organisation
            }
            elsif($mediaFileSourceFilename =~ m/\.mp4\Z/ && $iplayerTagCategories =~ m/[Ff]ilm/) {
                $mediaType = 'FILM';
                print("STATUS: Media file classified as: FILM.\n");
                open($nfofh, '<:encoding(UTF-8)', "$programDirectoryFullPath/kodi_metadata_templates/kodiNfoTemplateFilm.nfo");
                print("STATUS: Using FILM type rules to process the media file $mediaFileSourceFilename\n");
                print("STATUS: Creating <movie> type Kodi compatible nfo metadata file.\n");
            }
            elsif($mediaFileSourceFilename =~ m/\.mp4\Z/) {
                $mediaType = 'TV';
                print("STATUS: Media file classified as: TV.\n");
                # open the <episodedetails> nfo template
                open($nfofh, '<:encoding(UTF-8)', "$programDirectoryFullPath/kodi_metadata_templates/kodiNfoTemplateTvEpisode.nfo");
                # open the <tvshow> nfo template
                # TODO: open additional filehandle for the Kodi nfo file for a <tvshow>
                print("STATUS: Using TV type rules to process the media file $mediaFileSourceFilename\n");
                print("STATUS: Creating <epidsodedetails> type Kodi compatible nfo metadata file.\n");
            }
            else {
                $mediaType = 'UNKNOWN';
                print("ERROR: Media file with tag \'$iplayerTagType\' could not be classified as either FILM, TV or RADIO: $mediaFile\n");
                # TODO: Log it. 
                next;
            }
            while(my $line = <$nfofh>) {
                $kodiNfoString .= $line;
            }
            close($nfofh);

            # Populate the appropriate new kodi-compatible .nfo metadata file for the media file
            # Different .nfo templates are used depending on the media type; RADIO, FILM or TV, some tags are common to several types of nfo file
            # This is usually a simple manual transfer of get_iplayer XML tags into their Kodi equivalents 
            # but sometimes, additional processing or logic is required before the transfer is completed.
            
            # Kodi: <title>, Organisation: Filename component
            if($mediaType =~ m/\AFILM\Z/ || $mediaType =~ m/\ATV\Z/) {
                # Map get_iplayer <title>, <brand>, <name>, <longname>, <nameshort> to Kodi <title> for FILM and to $newNameShowName
                # Map get_iplayer <title>, <nameshort>, <name>, <longname> or <brand> to Kodi <title> for TV and to $newNameEpisodeName
                my @iplayerTitleTagCandidates;
                if($mediaType =~ m/\AFILM\Z/) {
                    @iplayerTitleTagCandidates = ('title', 'brand', 'name', 'longname', 'nameshort');
                    if(!defined($newNameShowName = transferMetadata(\$iplayerXmlString, \@iplayerTitleTagCandidates, \$kodiNfoString, 'title'))) {
                        # No formal name for this media file defined in the iplayer XML file.
                        # TODO: Process the filename or break here to leave this program for manual transfer.
                        print("WARNING: No name defined for this film in its iplayer XML metadata file. Falling back on using the filename $mediaFileSourceFilenameNoExtension as the film name instead.\n");
                        $newNameShowName = $mediaFileSourceFilenameNoExtension;
                    }
                    print("INFO: New filename is $newNameShowName\n");
                }
                elsif($mediaType =~ m/\ATV\Z/) {
                    if(defined($newNameEpisodeName = getMetadata(\$iplayerXmlString, 'episodeshort'))) {
                        setMetadataSingle(\$kodiNfoString, 'title', $newNameEpisodeName);
                        print("INFO: New TV programme episode name is $newNameEpisodeName\n");
                    }
                    elsif(defined($newNameEpisodeName = getMetadata(\$iplayerXmlString, 'episode', 'title'))) {
                        if($newNameEpisodeName =~ m/\. /) {
                            # the tag <episode> returned a result prefixed by the episode number, split it, take the last part
                            my @episodeArray = split('. ', $newNameEpisodeName);
                            $newNameEpisodeName = $episodeArray[-1];
                        }
                        if($newNameEpisodeName =~ m/\: /) {
                            # the tag <title> returned a result prefixed by the episode number, split it, take the last part
                            my @episodeArray = split(': ', $newNameEpisodeName);
                            $newNameEpisodeName = $episodeArray[-1];
                        }
                        setMetadataSingle(\$kodiNfoString, 'title', $newNameEpisodeName);
                        print("INFO: New TV programme episode name is $newNameEpisodeName\n");
                    }
                    else {
                        # No formal episode name for this media file defined in the iplayer XML file.
                        # TODO: Process the filename or break here to leave this program for manual transfer.
                        print("WARNING: No name defined for this TV programme in its iplayer XML metadata file. Falling back on using the filename $mediaFileSourceFilenameNoExtension as the TV programme name instead.\n");
                        $newNameEpisodeName = $mediaFileSourceFilenameNoExtension;
                    }
                }
            }

            # Kodi: <showtitle> (the name of the whole show)
            if($mediaType =~ m/\ATV\Z/){
                # Map get_iplayer <brand>, <nameshort>, first part of <name>, first part of <longname>, first part of <title> to Kodi <showtitle>
                if(!defined($newNameShowName = getMetadata(\$iplayerXmlString, 'brand', 'nameshort'))) {
                    # splitting the getMetadata tag candidates as some (estimate 10%?) legitimate <brand> and <nameshort> tags contain ': ' as part of the show title.
                    if(defined($newNameShowName = getMetadata(\$iplayerXmlString, 'title'))) {
                        my @showtitleArray = split(': ', $newNameShowName);
                        # Should split into three parts, showtitle, series, episodetitle, unless either one of the latter is missing, or showtitle itself has a ': ' in it
                        if(@showtitleArray <= 3) {
                            $newNameShowName = $showtitleArray[0];
                        }
                        else {
                            $newNameShowName = $showtitleArray[0] . ': ' . $showtitleArray[1];
                        }
                        setMetadataSingle(\$kodiNfoString, 'showtitle', $newNameShowName);
                    }
                    elsif(defined($newNameShowName = getMetadata(\$iplayerXmlString, 'longname', 'name'))) {
                        my @showtitleArray = split(': ', $newNameShowName);
                        # Should split into two parts, showtitle, series, unless either one of the latter is missing, or showtitle itself has a ': ' in it
                        if(@showtitleArray <= 2) {
                            $newNameShowName = $showtitleArray[0];
                        }
                        else {
                            # in the case that the showtitle itself has a ': ' in it, put it back together.
                            $newNameShowName = $showtitleArray[0] . ': ' . $showtitleArray[1];
                        }
                        setMetadataSingle(\$kodiNfoString, 'showtitle', $newNameShowName);
                    }
                    else {
                        # nothing obtained from any XML tags, fall back on using the filename for now.
                        # TODO: Process the filename or break here to leave this program for manual transfer.
                        print("WARNING: No name defined for this TV programme in its iplayer XML metadata file. Falling back on using the filename $mediaFileSourceFilenameNoExtension as the TV programme name instead.\n");
                        $newNameShowName = $mediaFileSourceFilenameNoExtension;
                    }
                }
                else {
                    # got a match from one of the two most accurate tags <brand> or <nameshort>. No need to post-process.
                    setMetadataSingle(\$kodiNfoString, 'showtitle', $newNameShowName);
                }
                print("INFO: New filename is $newNameShowName\n");
            }

            # Kodi: <outline>
            if($mediaType =~ m/\AFILM\Z/) {
                # Map get_iplayer <descshort>, <desc> or <descmedium> to Kodi <outline>
                my @iplayerShortDescriptionTagCandidates = ('descshort', 'desc', 'descmedium');
                transferMetadata(\$iplayerXmlString, \@iplayerShortDescriptionTagCandidates, \$kodiNfoString, 'outline');
            }

            # Kodi: <plot>
            if($mediaType =~ m/\AFILM\Z/ || $mediaType =~ m/\ATV\Z/) {
                # Map get_iplayer <desclong>, <descmedium>, <desc> or <descshort> to Kodi <plot>
                my @iplayerLongDescriptionTagCandidates = ('desclong', 'descmedium', 'desc', 'descshort');
                transferMetadata(\$iplayerXmlString, \@iplayerLongDescriptionTagCandidates, \$kodiNfoString, 'plot');
            }

            # Kodi: <runtime>
            if($mediaType =~ m/\AFILM\Z/ || $mediaType =~ m/\ATV\Z/) {
                # Map get_iplayer <duration>, <durations> to Kodi <runtime> indirectly because conversion from seconds to minutes required
                # my @iplayerDurationTagCandidates = ('duration');
                my $mediaFileDuration = getMetadata(\$iplayerXmlString, 'duration');
                if(defined($mediaFileDuration)) {
                    setMetadataSingle(\$kodiNfoString, 'runtime', int($mediaFileDuration/60));
                    print("INFO: Media file runtime is " . $mediaFileDuration/60 . "minutes.\n");
                }
                else {
                    my $mediaFileRuntime = getMetadata(\$iplayerXmlString, 'runtime');
                    if(defined($mediaFileRuntime)) {
                        if($mediaFileRuntime != 0) {
                            setMetadataSingle(\$kodiNfoString, 'runtime', $mediaFileRuntime);
                            print("INFO: Media file runtime is " . $mediaFileDuration . "minutes.\n");
                        }
                    }
                    # No else, as this value is overwritten in the nfo file with the exact runtime obtained from the media file itself when the file is first played in Kodi
                }
            }

            # Organisation: Filename component for FILM and TV 
            if($mediaType =~ m/\AFILM\Z/ || $mediaType =~ m/\ATV\Z/) {
                # The YEAR of get_iplayer <firstbcastyear> is almost always wrong for films for it choses the TV broadcast date rather than the cinema release date.
                my @iplayerFirstBroadcastTagCandidates = ('firstbcastyear');
                my $firstBroadcastYear = getMetadata(\$iplayerXmlString, @iplayerFirstBroadcastTagCandidates);
                
                # If no get_iplayer <firstbcastyear> tag found then there are two choices:
                # EITHER search for <firstbcast>, <firstbcastdate> and extract the year from the full date.
                # OR attempt to download the iplayer programme webpage and extract the "firstBroadcast" information from there
                # NB: firstBroadcastYear could still be undef after this - which is fine and is handled when building the newFilenameComplete later
                if(!defined($firstBroadcastYear)) {
                    print("No <firstbcastyear> tag found, searching for <firstbcast>, <firstbcastdate> tags instead");
                    @iplayerFirstBroadcastTagCandidates = ('firstbcast', 'firstbcastdate');
                    $firstBroadcastYear = getMetadata(\$iplayerXmlString, @iplayerFirstBroadcastTagCandidates);
                    $firstBroadcastYear =~ s/\A([12][0-9]{3})-/$1/;
                    if(1900 < $firstBroadcastYear && $firstBroadcastYear < 2050) {
                        $newNameYear = $firstBroadcastYear;
                    }
                }
                else {
                    $newNameYear = $firstBroadcastYear;
                }
                if($mediaType =~ m/\AFILM\Z/) {
                    # Experimental, go to the BBC website, download the program webpage and extract "firstBroadcast" information
                    # which may be more accurate than the date in the iplayer XML metadata file for films.
                    my $webifiedProgrammeName = lc($newNameShowName);
                    $webifiedProgrammeName =~ s/\s/-/g;
                    # TODO: Check if $webifiedProgrammeName is needed on the end of the URL (whether LWP::Simple->get() can handle 301 redirection)
                    my $programmeUrl = "https://www.bbc.co.uk/iplayer/episode/$mediaFilePid";#/$webifiedProgrammeName";
                    print("STATUS: Attempting to download programme's iplayer webpage $programmeUrl\n");
                    my $webpage = get($programmeUrl);
                    if(defined($webpage)) {
                        # TODO: Searching the whole file in a single string is probably quite inefficient
                        # It works but should it be changed? It's very short and neat compared to the alternatives (see file: test_web_parsing.pl)
                        my $downloadedBroadcastYear;
                        if($webpage =~ m/"firstBroadcast":"([1-9]{4})"/s) {
                            $downloadedBroadcastYear = $1;
                        }
                        else {
                            print("STATUS: Could not find a more accurate year of first broadcast on the programme's iplayer webpage.\n");
                            $newNameYear = $firstBroadcastYear;
                        }
                        if(length($downloadedBroadcastYear) == 4) {
                            print("SUCCESS: Found year of first broadcast from programme's iplayer webpage: $downloadedBroadcastYear\n");
                            print("INFO: Checking if the year found on programme's webpage ($downloadedBroadcastYear) is earlier than the year found in the iplayer XML metadata file ($firstBroadcastYear).\n");
                            if($downloadedBroadcastYear <= $firstBroadcastYear) {
                                print("INFO: The year found on programme's webpage ($downloadedBroadcastYear) is earlier, updating the film's Kodi nfo metadata file.\n");
                                $newNameYear = $downloadedBroadcastYear;
                            }
                        }
                    }
                    else{
                        print("WARNING: Unable to download the programme's iplayer webpage.\n");
                    }
                }
            }

            # TODO: Kodi: <namedseason number="1"> for TvShow

            # Organisation: Series directory name component for TV
            # Kodi ignores series directories, so their name does not matter except for human-readable reasons. 
            if($mediaType =~ m/\ATV\Z/) {
                if(defined($newNameSeriesName = getMetadata(\$iplayerXmlString, 'series'))) {
                    # Deal with series name being the same as the show name, set $newNameSeriesName to undef
                    if($newNameSeriesName =~ m/\A$newNameShowName\Z/) {
                        $newNameSeriesName = undef;
                        print("INFO: Series name is the same as the Show name for this TV programme, omitting Series name and subdirectory.\n");
                    }
                    # Deal with simple 'Series NN' series names, adding zero-padding to any series number under 10
                    elsif($newNameSeriesName =~ m/\ASeries [0-9]{1,}\Z/) {
                        # Zero-pad any series number under 10
                        if($newNameSeriesName =~ m/\ASeries [0-9]{1}\Z/) {
                            $newNameSeriesName =~ s/\A(Series) ([0-9]{1})\Z/$1 0$2/;
                        }
                    }
                    # Deal with year range series names e.g. 2019-2020
                    elsif($newNameSeriesName =~ m/\A[1-2]{1}[0-9]{3}-[1-2]{1}[0-9]{3}\Z/) {
                        # This is totally fine.
                    }
                    else {
                        # Deal with a specifically named season, it's *probably* fine but add season number as a prefix for directory sorting purposes
                        # TODO: Kodi: <namedseason number="1"> for TvShow nfo file
                        if(defined(my $seriesNumber = getMetadata(\$iplayerXmlString, 'seriesnum'))) {
                            if(length($seriesNumber) == 1) {
                                $seriesNumber = '0' . $seriesNumber;
                            }
                            $newNameSeriesName = $seriesNumber . '_' . $newNameSeriesName;
                        }
                    }
                }
                else {
                    # No Series name at all. This is fine and will be handled later
                }
            }

            # Organisation: Filename name component for TV
            # <sesort> (newer), <senum> (older) should hold S01E01 format series/episode string, also <sesortx> (newer) and <sesortx> 01x01 format series/episode string
            # This is the easiest option.
            # <sesort> and <senum>
            # or <seriesnum> and <episodenum> tags for pure numeric values
            if($mediaType =~ m/\AFILM\Z/ || $mediaType =~ m/\ATV\Z/) {
                if(defined($newNameSeriesEpisodeCode = getMetadata(\$iplayerXmlString, 'sesort', 'senum'))) {
                    # Some continuously running programmes have a YYYYMMDDhhmm date code instead of a 's01e01' format identifier, reformat this for ease of reading
                    if($newNameSeriesEpisodeCode =~ m/\A[0-9]{12}\Z/) {
                        # $newNameSeriesEpisodeCode =~ s/\A([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\Z/$1-$2-$3\_$4:$5/;
                        $newNameSeriesEpisodeCode =~ s/\A([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{4})\Z/$1-$2-$3/;
                        $newNameSeriesNumber = $newNameSeriesEpisodeCode; # TODO: Test if named series cause trouble with Series Artwork naming and detection by Kodi.
                    }
                    # Most are of the format s01e01, capitalise it. Very rarely, a suffixed letter will be added for a mulit-part episode.
                    if($newNameSeriesEpisodeCode =~ m/\As[0-9]{2}e[0-9]{2,3}[a-z]?\Z/) {
                        $newNameSeriesEpisodeCode = uc($newNameSeriesEpisodeCode);
                        $newNameSeriesNumber = $newNameSeriesEpisodeCode;
                        $newNameSeriesNumber =~ s/\AS[0-9]{2}E(.*)\Z/$1/;
                    }
                }
                else {
                    # No season or episode information defined. Unlikely that the <seasonnum> or <episodenum> tags will be filled either. Get a date code instead
                    ($newNameSeriesEpisodeCode) =  split('T', getMetadata(\$iplayerXmlString, 'firstbcastdate', 'firstbcast'));
                    if(!defined($newNameSeriesEpisodeCode)) {
                        print("WARNING: Unable to define a series, episode or date code for this programme.\n");
                        # Unlikely that a $newNameSeriesNumber, which is needed to name Series Artwork, will be appropriate here.
                    }
                }
            }

            # Kodi: <premiered>
            # NB: This will be wrong for films, but there's not much that can be done unless a more correct firstBroadcastYear is found above 
            # and bodged in place of the year portion of the date here, leaving the month and day incorrect? TODO: Do it?
            if($mediaType =~ m/\AFILM\Z/) {
                my @iplayerFirstBroadcastTagCandidates = ('firstbcastdate');
                my $firstBroadcastDate = transferMetadata(\$iplayerXmlString, \@iplayerFirstBroadcastTagCandidates, \$kodiNfoString, 'premiered');
                if(!defined($firstBroadcastDate)) {
                    # Tag samples:
                    # <firstbcast>2009-09-18T21:50:00+01:00</firstbcast>
                    # <firstbcastdate>2009-09-18</firstbcastdate>
                    ($firstBroadcastDate) = split('T', getMetadata(\$iplayerXmlString, 'firstbcast'));
                    if(defined($firstBroadcastDate)) {
                        setMetadataSingle(\$kodiNfoString, 'premiered', $firstBroadcastDate);
                    }
                }
            }

            # Kodi: <aired>
            if($mediaType =~ m/\ATV\Z/) {
                my @iplayerFirstBroadcastTagCandidates = ('firstbcastdate');
                my $firstBroadcastDate = transferMetadata(\$iplayerXmlString, \@iplayerFirstBroadcastTagCandidates, \$kodiNfoString, 'aired');
                if(!defined($firstBroadcastDate)) {
                    ($firstBroadcastDate) = split('T', getMetadata(\$iplayerXmlNewerType, 'firstbcast'));
                    if(defined($firstBroadcastDate)) {
                        setMetadataSingle(\$kodiNfoString, 'aired', $firstBroadcastDate);
                    }
                }
            }

            # Kodi: <genre>
            # TODO: for TV programmes, this should go in the TvShow nfo file. The TvEpisode nfo files will have this value ignored if <genre> is present in a parent dir TvShow nfo File.
            if($mediaType =~ m/\AFILM\Z/ || $mediaType =~ m/\ATV\Z/) {
                # Transfer iplayer <category> and <categories> tags to Kodi's <genre> tags
                if(transferMetadataCategories(\$iplayerXmlString, \$kodiNfoString)) {
                    print("SUCCESS: Finished transferring iplayer categories to Kodi genres.\n");
                }
                else {
                    print("ERROR: Unable to transfer iplayer categories to Kodi genres.\n");
                }
            }

            # Kodi: <bbc_pid> 
            # NB: not an official Kodi tag, but added to keep a record of the official identity of the original BBC programme
            # Add to all
            if($mediaType =~ m/\AFILM\Z/ || $mediaType =~ m/\ATV\Z/) {
                if(setMetadataSingle(\$kodiNfoString, 'bbc_pid', $mediaFilePid)) {
                    print("SUCCESS: Added iplayer programme PID to Kodi nfo metadata file.\n");
                }
                else {
                    print("ERROR: Unable to add iplayer programme PID to Kodi nfo metadata file.\n");
                }
            }

            # Change empty XML tags from <tag/> to <tag></tag> to satisfy Kodi (even though </tag> is still technically valid XML)
            $kodiNfoString =~ s/<(.*)\/>/<$1><\/$1>/g;
            print("INFO: Created the following Kodi nfo metadata file for the film $newNameShowName.\n");
            # Print fully poplulated Kodi nfo metadata string and a final newline
            print("$kodiNfoString" . "\n");

            # Now should have all information necessary to create a new Kodi compatible filename
            # Occasionally a programme or episode name has been observed to contain one or more '/' characters. Most often because of a date in the programme name.
            # Also replace whitespace in file and directory names with the chosen separator character
            foreach($newNameShowName, $newNameSeriesName, $newNameEpisodeName, $newNameSeriesNumber, $newNameSeriesEpisodeCode, $newNameYear) {
                if(defined($_)) {
                    $_ =~ s/\//-/g;
                    $_ =~ s/\s/$separator/g;
                }
            }
            # Build the filenames as appropriate for each media type
            if(defined($newNameYear)) {
                $newNameYear = $separator . '(' . $newNameYear . ')';
            }
            if(defined($newNameSeriesEpisodeCode)) {
                $newNameSeriesEpisodeCode = $separator . $newNameSeriesEpisodeCode;
            }
            # TODO: Decide if it is worth adding the episode name to the filename in the cases where it is just "Episode 1"... and is placed redundantly right after the S01E01 code.
            if(defined($newNameEpisodeName)) {
                if($newNameEpisodeName =~ m/\A[Ee]pisode [0-9]{1,3}\Z/) {
                    $newNameEpisodeName = undef;
                }
                else {
                    $newNameEpisodeName = $separator . $newNameEpisodeName;
                }
            }
            
            # Assemble the new Kodi compatible filename
            foreach($newNameShowName, $newNameYear, $newNameSeriesEpisodeCode, $newNameEpisodeName) {
                if(defined($_)) {
                    $newFilenameComplete .= $_;
                }
            }
            $newFilenameComplete = $newNameShowName . $newNameYear . $newNameSeriesEpisodeCode . $newNameEpisodeName;    

            # Now create the destination directory full path - which has the same name as the files it will contain
            if($mediaType =~ m/\AFILM\Z/) {
                $mediaFileDestinationDirectory = $destinationDir . $destinationSubdirFilm . $newFilenameComplete . '/';
            }
            elsif($mediaType =~ m/\ATV\Z/) { # Ultimiately MUSIC - or rather RADIO and PODCASTS will follow the same directory structure as TV
                $mediaFileDestinationDirectory = $destinationDir . $destinationSubdirTv . $newNameShowName . '/' . $newNameSeriesName . '/' . $newFilenameComplete . '/';
                $mediaFileSeriesAtworkDirectory = $destinationDir . $destinationSubdirTv . $newNameShowName . '/';
            }
            
            
            print("INFO: Destination directory for the film is: $mediaFileDestinationDirectory\n");
            print("INFO: Complete filename for the film is: $newFilenameComplete\n");
            if(!-d $mediaFileDestinationDirectory) {
                if(!File::Path->make_path($mediaFileDestinationDirectory)) {
                    print("ERROR: Unable to create destination directory for this film: $mediaFileDestinationDirectory\n");
                }
            }
            else {
                print("INFO: Destination directory already exists.\n");
            }

            # Write the completed Kodi nfo file straight into the destination directory
            my $destinationfofh;
            open($destinationfofh, '>:encoding(UTF-8)', $mediaFileDestinationDirectory . $newFilenameComplete . '.nfo');
            print($destinationfofh $kodiNfoString);
            close($destinationfofh);

            # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            # START OF THE COMMON SECTION DEALING WITH METADATA FILES
            # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

            # NFO - COMMON TO ALL MEDIA
            # Copy any EXISTING, OLD Kodi nfo file from the source folder to the destination folder adding the suffix .old
            # iplayer-generated Kodi nfo files are old, obsolete and are not used in the creation of the new Kodi nfo files. 
            if(-f . '.nfo') {
                &$transfer($mediaFileFullPathNoExtension . '.nfo', $mediaFileDestinationDirectory . $newFilenameComplete . '.nfo.old');
            } # There is deliberately no 'else' clause for nfo files here.

            # XML - COMMON TO ALL MEDIA
            # transfer the original XML programme metadata file to the destination directory
            if(-f $metadataFileXml) {
                &$transfer($metadataFileXml, $mediaFileDestinationDirectory . $newFilenameComplete . '.xml');
                if(-f $metadataFileXml . '.old') {
                    &$transfer($metadataFileXml . '.old', $mediaFileDestinationDirectory . $newFilenameComplete . '.xml.old');
                }
            } # There is no else. If an XML metadata file doesn't exist already and hasn't been downloaded by now, it is not obtainable at all and we really shouldn't have got this far without one.
            
            # MP4/M4A - COMMON TO ALL MEDIA
            # transfer the media file itself to the destination directory. No if -f check, existance already proven
            if($mediaType =~ m/\AFILM\Z/ || m/\ATV\Z/) {
                &$transfer($mediaFile, $mediaFileDestinationDirectory . $newFilenameComplete . '.mp4');
            }
            elsif(m/\ARADIO\Z/) {
                &$transfer($mediaFile, $mediaFileDestinationDirectory . $newFilenameComplete . '.m4a');
            }
             
            # JPG - COMMON TO ALL MEDIA
            # transfer the metadata jpg thumbnail image to the destination directory as 'fanart' image type
            # after checking it is the largest 1920x1080 resolution, redownloading if not.
            # NB: $mediaFileThumbnail MUST be defined BEFORE the get_iplayer XML metadata is re-downloaded as that changes the <thumbnail> URL information from what was originally downloaded.
            if(-f $mediaFileFullPathNoExtension . '.jpg') {
                if ($mediaFileThumbnail !~ m/1920x1080/) {
                    print("WARNING: jpg metadata file exists but is low resolution. Attempting to download high resolution version.");
                    my ($newJpg) = downloadMetadataFile($mediaFileDestinationDirectory, $newFilenameComplete . '-fanart', $mediaFilePid, $mediaFileVersion, 'jpg');
                    if(-f $newJpg) {
                        print("SUCCESS: Downloaded a new high resolution jpg metadata file to the destination directory as a fanart image.\n");
                    }
                    else {
                        if(-f $mediaFileFullPathNoExtension . '.jpg') {
                            print("WARNING: No new high resolution jpg metadata file could be downloaded, copying old low resolution jpeg metadata file to destination directory.\n");
                            &$transfer($mediaFileFullPathNoExtension . '.jpg', $mediaFileDestinationDirectory . $newFilenameComplete . '-fanart.jpg');
                        }
                        else {
                            print("WARNING: Neither a new high resolution jpg megadata file can be downloaded, nor is there an existing low resolution jpg metadata file available for this programme.\n");
                        }
                    }
                }
                else {
                    &$transfer($mediaFileFullPathNoExtension . '.jpg', $mediaFileDestinationDirectory . $newFilenameComplete . '-fanart.jpg');
                    print("INFO: Transferred jpg image file to destination directoty as a fanart image.\n");
                }
            }
            else {
                my ($newJpg) = downloadMetadataFile($mediaFileDestinationDirectory, $newFilenameComplete . '-fanart', $mediaFilePid, $mediaFileVersion, 'jpg');
                if(-f $newJpg) {
                    print("SUCCESS: Downloaded a new high resolution jpg image file to the destination directory as a fanart image.\n");
                }
            }

            # SERIES.JPG - COMMON TO ALL MEDIA EXCEPT FILMS
            # Transfer *series* metadata jpg thumbnail image to the destination *base* directory as 'fanart' image type, with the filename identifying which series it belongs to
            if(($mediaType =~ m /\ARADIO\Z/) || ($mediaType =~ m /\ATV\Z/)) {
                if(defined($newNameSeriesNumber)) {
                    # To prevent it being downloaded for every episode processed in a series, check for its existance in the DESTINATION directory
                    my $seriesArtworkFilename = 'Season' . $newNameSeriesNumber . '-fanart.jpg';
                    my $seriesArtworkFullPath = $mediaFileSeriesAtworkDirectory . $seriesArtworkFilename;
                    if(-f $seriesArtworkFullPath) {
                        print("INFO: A programme series jpg image file $seriesArtworkFilename already exists in the destination directory.\n");
                    }
                    else {
                        my ($newSeriesJpg) = downloadMetadataFile($mediaFileSeriesAtworkDirectory, $seriesArtworkFilename, $mediaFilePid, $mediaFileVersion, 'series.jpg');
                        if(-f $newSeriesJpg) {
                            print("SUCCESS: Downloaded a new programme series jpg image file to the destination directory.\n");
                        }
                        else {
                            print("WARNING: Unable to download a new programme series jpg image file to the destination directory.\n");
                        }
                    }
                }
            }

            # SQUARE.JPG -EXCLUSIVE TO RADIO
            # Transfer *square* metadata jpg thumbnail image to the destination directory as 'thumb' image type
            # None have been downloaded before...
            if($mediaType =~ m /\ARADIO\Z/) {
                if(-f $mediaFileFullPathNoExtension . '-square.jpg') {
                    &$transfer($mediaFileFullPathNoExtension . '-square.jpg', $mediaFileDestinationDirectory . $newFilenameComplete . '-thumb.jpg');
                }
                else {
                    my ($newSquareJpg) = downloadMetadataFile($mediaFileDestinationDirectory, $newFilenameComplete, $mediaFilePid, $mediaFileVersion, '-thumb.jpg');
                    if(-f $newSquareJpg) {
                        print("Success: Downloaded a new programme square jpg file to the destination directory.\n");
                    }
                    else {
                        print("WARNING: Unable to download a new programme square jpg file to the destination directory.\n");
                    }
                }
            }

            # SRT - COMMON TO ALL MEDIA EXCEPT RADIO
            # Transfer subtitles file to the destination directory
            # NB: Not using the dotted, first-letter-capitalised language pre-suffix e.g. foo_S01E01.English.srt, foo_S01E01.French.srt
            if(-f $mediaFileFullPathNoExtension . '.srt') {
                &$transfer($mediaFileFullPathNoExtension . '.srt', $mediaFileDestinationDirectory . $newFilenameComplete . '.srt');
            }
            else {
                my ($newSrt) = downloadMetadataFile($mediaFileDestinationDirectory, $newFilenameComplete, $mediaFilePid, $mediaFileVersion, 'srt');
                if(-f $newSrt) {
                    print("SUCCESS: Downloaded a new subtitles file to the destination directory.\n");
                }
                else {
                    print("WARNING: Unable to download a new subtitles file to the destination directory.\n");
                }
            }

            # CREDITS.TXT - COMMON TO ALL MEDIA
            # Transfer programme credits text file to the destination directory
            if(-f $mediaFileFullPathNoExtension . '.credits.txt') {
                &$transfer($mediaFileFullPathNoExtension . '.credits.txt', $mediaFileDestinationDirectory . $newFilenameComplete . '.credits.txt');
            }
            else {
                my ($newCreditsTxt) = downloadMetadataFile($mediaFileDestinationDirectory, $newFilenameComplete, $mediaFilePid, $mediaFileVersion, 'credits.txt');
                if(-f $newCreditsTxt) {
                    print("SUCCESS: Downloaded a new programme credits text file to the destination directory.\n");
                }
                else {
                    print("WARNING: Unable to download a new programme credits text file to the destination directory.\n");
                }
            }

            # CUE - EXCLUSIVE TO RADIO
            # Transfer music track listing cue sheet to the destination directory
            # NB: get_iplayer's github wiki notes that cue sheets are often wrong: https://github.com/get-iplayer/get_iplayer/wiki/proginfo#cuesheet
            if($mediaType =~ m /\ARADIO\Z/) {
                if(-f $mediaFileFullPathNoExtension . '.cue') {
                    &$transfer($mediaFileFullPathNoExtension . '.cue', $mediaFileDestinationDirectory . $newFilenameComplete . '.cue');
                }
                else {
                    my ($newCue) = downloadMetadataFile($mediaFileDestinationDirectory, $newFilenameComplete, $mediaFilePid, $mediaFileVersion, 'cue');
                    if(-f $newCue) {
                        print("SUCCESS: Downloaded a new programme music cue sheet file to the destination directory.\n");
                    }
                    else {
                        print("WARNING: Unable to download a new programme music cue sheet file to the destination directory.\n");
                    }
                }
            }

            # TRACKS.TXT - COMMON TO ALL MEDIA
            # Transfer music track listing text file to the destination directory
            # NB: get_iplayer's github wiki notes that track lists are often wrong: https://github.com/get-iplayer/get_iplayer/wiki/proginfo#tracklist
            if(-f $mediaFileFullPathNoExtension . '.tracks.txt') {
                &$transfer($mediaFileFullPathNoExtension . '.tracks.txt', $mediaFileDestinationDirectory . $newFilenameComplete . '.tracks.txt');
            }
            else {
                my ($newTracksTxt) = downloadMetadataFile($mediaFileDestinationDirectory, $newFilenameComplete, $mediaFilePid, $mediaFileVersion, 'tracks.txt');
                if(-f $newTracksTxt) {
                    print("SUCCESS: Downloaded a new programme music cue sheet file to the destination directory.\n");
                }
                else {
                    print("WARNING: Unable to download a new programme music cue sheet file to the destination directory.\n");
                }
            }
        }
        else { 
            print("Starting basic parsing of programme information using filename only...\n");
            # Probably cannot identify whether the media file is a film, tv programme, radio/podcast or music
            # File extension, mp4 or m4a, is the main identifier of media type.
            # Absence of S01E01 could indicate film
            # Tidy up filenames into a kodi compatible format and after that there's probably little that can be done without manual intervention.
            # TODO: Investigate metadata encoded within the media files using Atomic Parsley?
            if($mediaFileSourceFilename =~ m/\.m4a\Z/) {
                # $mediaType = 'RADIO';
                # print("Media file classified as: RADIO\n");
            }
            elsif($mediaFileSourceFilename =~ m/\.mp4\Z/) {
                # $mediaType = 'TV';
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
        print("\n");
    } 
}
else {
    printUsageInformation();
    exit 1;
}