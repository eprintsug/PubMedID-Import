=head1 NAME

EPrints::Plugin::Import::PubMedID

=cut

package EPrints::Plugin::Import::PubMedID;

use strict;


#UZH CHANGE FOR USING EPrints
use EPrints;
#END UZH CHANGE FOR USING EPrints
use EPrints::Plugin::Import;
# UZH CHANGE ZORA-530 2016/11/08/mb
use LWP::Simple;
use LWP::UserAgent;
use XML::LibXML;
# END UZH CHANGE
use URI;

use base 'EPrints::Plugin::Import';

sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new( %params );

	$self->{name} = "PubMed ID";
	$self->{visible} = "all";
	#UZH CHANGE FOR REDUCING PLACES OF DISPLAY
	$self->{produce} = [ 'list/eprint' ];
	#END UZH CHANGE FOR REDUCING PLACES OF DISPLAY

	$self->{EFETCH_URL} = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&retmode=xml&rettype=full';

	return $self;
}

sub input_fh
{
	my( $plugin, %opts ) = @_;

	my @ids;

	my $pubmedxml_plugin = $plugin->{session}->plugin( "Import::PubMedXML", Handler=>$plugin->handler );
	$pubmedxml_plugin->{parse_only} = $plugin->{parse_only};
	my $fh = $opts{fh};
	
	# UZH CHANGE FOR DUPLICATE CONTROL
	# UZH CHANGE ZORA-455 2015/12/16/mb - multilingual warning message
	# UZH CHANGE ZORA-514 2016/10/24/mb - improved user handling, improved readability of code
	my $db = $plugin->{session}->get_database;
	my $pxml = $plugin->{session}->get_repository->xml;
	
	my $curuser = $plugin->{session}->get_repository->current_user->get_value("userid");
	
	NEWPMID: while( my $pmid = <$fh> )
	{
		$pmid =~ tr/\x80-\xFF//d;
		$pmid =~ s/^\s+//;
		$pmid =~ s/\s+$//;
		next if ($pmid eq "");
		if( $pmid !~ /^[0-9]+$/ ) # primary IDs are always an integer
		{
			$plugin->warning( 
				$plugin->html_phrase( 
					"invalid_pmid",
					pmid => $pxml->create_text_node( $pmid )
				)
			);
			next;
		}
		
		my $sql = "select eprint.eprintid, eprint.eprint_status from eprint where eprint.pubmedid=?";
		my $sth = $db->prepare ( $sql );
		$sth->bind_param( 1, $pmid, DBI::SQL_CHAR);
		$sth->execute();

		my $duplicate_warning;
		my $duplicate_warning_header;
		my $ctr = 0;
		my $msgoutput = $plugin->{session}->make_doc_fragment;

		CURRENTDUPLICATES: while( my @values = $sth->fetchrow_array )
		{
			my $eprint_phrase;
			my $depositor_phrase;
			my $eprint_status_phrase;
			my $subjects_phrase;
			
			my $duplicate_id = $values[0];
			my $duplicate_status = $values[1];
			
			if ($duplicate_status eq "deletion")
			{
				next CURRENTDUPLICATES;
			}
			else
			{
				$ctr++;
			}
			if ($ctr == 1)
			{
				$duplicate_warning_header = $plugin->html_phrase( 
					"duplicate_warning_header",
					pmid => $pxml->create_text_node( $pmid )
				);
				$msgoutput->appendChild( $duplicate_warning_header );
			}
			
			if ($duplicate_status eq "archive")
			{
				my $eprint_xml = $pxml->parse_string( "<a href='http://" . $plugin->{session}->get_repository->get_conf("host") . "/" . $duplicate_id . "/'>" . $duplicate_id . "</a>" );
				my $eprint_element = $eprint_xml->getDocumentElement;
				$eprint_phrase = $plugin->{session}->make_doc_fragment;
				$eprint_phrase->appendChild( $eprint_element );
			}
			else
			{
				$eprint_phrase = $pxml->create_text_node( $duplicate_id );
			}
			
			#
			# get the user associated with the already existing eprint
			#
			my $sql_user = "select user.userid, user.name_honourific, user.name_given, user.name_family from eprint, user where eprint.userid=user.userid and eprint.pubmedid=?";
			my $sth_user = $db->prepare ( $sql_user );
			$sth_user->bind_param( 1, $pmid, DBI::SQL_CHAR);
			$sth_user->execute();
			
			#
			# prepare the depositor phrase for an unknown user
			#
			$depositor_phrase = $plugin->html_phrase( "unknown_user" );
			
			#
			# if deposited by current user or another user, adjust depositor phrase
			#
			while( my @user_values = $sth_user->fetchrow_array )
			{
				my $user_userid = $user_values[0];
				my $user_name_honourific = $user_values[1];
				my $user_name_given = $user_values[2];
				my $user_name_family =  $user_values[3];
				$user_name_honourific =~ s/^\s+|\s+$//;     # trim whitespace on both ends
				$user_name_honourific =~ s/[^\.]$/$1./;   
				$user_name_given =~ s/^\s+|\s+$//;          # trim whitespace on both ends
				$user_name_family =~ s/^\s+|\s+$//;         # trim whitespace on both ends

				if ($curuser == $user_userid)
				{
					$depositor_phrase = $plugin->html_phrase( "owned" );
				}
				else
				{
					$depositor_phrase = $plugin->html_phrase( 
						"deposited",
						name_honourific => $pxml->create_text_node( $user_name_honourific ),
						name_given => $pxml->create_text_node(  $user_name_given ),
						name_family => $pxml->create_text_node( $user_name_family )
					);
				}
			}
			$sth_user->finish;
			
			$eprint_status_phrase = $plugin->html_phrase( $duplicate_status );

			my $tmpeprint = $plugin->{session}->get_repository->get_dataset( "eprint" )->get_object( $plugin->{session}, $duplicate_id );
			if ($tmpeprint->is_set( "subjects"))
			{
				my $subjects_string = "<span>" . $pxml->to_string($tmpeprint->render_value("subjects")) . "</span>";
				$subjects_string =~ s/<a([^>]*)>/<a $1 target='_blank'>/g;
				my $subjects_xml = $pxml->parse_string( $subjects_string );
				my $subjects_element = $subjects_xml->getDocumentElement;
				$subjects_phrase = $plugin->{session}->make_doc_fragment;
				$subjects_phrase->appendChild( $subjects_element );
			}
			else
			{
				$subjects_phrase = $plugin->html_phrase( "nosubject" );
			}

			$duplicate_warning = $plugin->html_phrase( 
				"duplicate_warning",
				eprintid => $eprint_phrase,
				depositor => $depositor_phrase,
				eprint_status => $eprint_status_phrase,
				collections => $subjects_phrase
			);

			$msgoutput->appendChild( $duplicate_warning );
		}
		$sth->finish;
		
		if ($duplicate_warning_header ne "")
		{
			$plugin->handler->message( "warning", $msgoutput);
			next NEWPMID;
		}
		# END UZH CHANGE ZORA-514
		# END UZH CHANGE ZORA-455
		# END UZH CHANGE FOR DUPLICATE CONTROL

		# Fetch metadata for individual PubMed ID 
		# NB. EFetch utility can be passed a list of PubMed IDs but
		# fails to return all available metadata if the list 
		# contains an invalid ID
		# UZH CHANGE ZORA-530 2016/11/08/mb support of https protocol
		# my $url = URI->new( $plugin->{EFETCH_URL} );
		# $url->query_form( $url->query_form, id => $pmid );
		
		my $xml = $plugin->get_pubmed_data( $pmid );

		# my $xml = EPrints::XML::parse_url( $url );
		# END UZH CHANGE
		my $root = $xml->documentElement;

		if( $root->nodeName eq 'ERROR' )
		{
			EPrints::XML::dispose( $xml );
			# UZH CHANGE ZORA-455 2015/12/16/mb - multilingual warning message
			$plugin->warning( 
				$plugin->html_phrase( 
					"nomatch",
					pmid => $pxml->create_text_node( $pmid )
				)
			);
			# END UZH CHANGE ZORA-455 
			
			next;
		}

		foreach my $article ($root->getElementsByTagName( "PubmedArticle" ))
		{
			my $item = $pubmedxml_plugin->xml_to_dataobj( $opts{dataset}, $article );
			if( defined $item )
			{
				push @ids, $item->get_id;
			}
		}

		EPrints::XML::dispose( $xml );
	}

	return EPrints::List->new( 
		dataset => $opts{dataset}, 
		session => $plugin->{session},
		ids=>\@ids );
}


# UZH CHANGE ZORA-530 2016/11/08/mb
sub get_pubmed_data
{
	my ( $plugin, $pmid ) = @_;
	
	my $xml;
	my $response;
	
	my $parser = XML::LibXML->new();
	$parser->validation(0);
	
	my $host = $plugin->{session}->get_repository->config( 'host ');
	my $request_retry = 3;
	my $request_delay = 10;
	
	my $url = URI->new( $plugin->{EFETCH_URL} );
	$url->query_form( $url->query_form, id => $pmid );
	
	my $req = HTTP::Request->new( "GET", $url );
	$req->header( "Accept" => "text/xml" );
	$req->header( "Accept-Charset" => "utf-8" );
	$req->header( "User-Agent" => "EPrints 3.3.x; " . $host  );
	
	my $request_counter = 1;
	my $success = 0;
	
	while (!$success && $request_counter <= $request_retry)
	{
		my $ua = LWP::UserAgent->new;
		$ua->env_proxy;
		$ua->timeout(60);
		$response = $ua->request($req);
		$success = $response->is_success;
		$request_counter++;
		sleep $request_delay if !$success;
	}

	if ( $response->code != 200 )
	{
		print STDERR "HTTP status " . $response->code .  " from ncbi.nlm.nih.gov for PubMed ID $pmid\n";
	}
	
	if (!$success)
	{	
		$xml = $parser->parse_string( '<?xml version="1.0" ?><eFetchResult><ERROR>' . $response->code . '</ERROR></eFetchResult>' );
	}
	else
	{
		$xml = $parser->parse_string( $response->content );
	}
	
	return $xml;
}


1;

=head1 COPYRIGHT

=for COPYRIGHT BEGIN

Copyright 2000-2011 University of Southampton.

=for COPYRIGHT END

=for LICENSE BEGIN

This file is part of EPrints L<http://www.eprints.org/>.

EPrints is free software: you can redistribute it and/or modify it
under the terms of the GNU Lesser General Public License as published
by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

EPrints is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
License for more details.

You should have received a copy of the GNU Lesser General Public
License along with EPrints.  If not, see L<http://www.gnu.org/licenses/>.

=for LICENSE END

