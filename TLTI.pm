#####################################################################
#
# Turnitin LTI interface
#
####################################################################
# This file is stand-alone perl package to implement the basic LTI
# and soap interface to Turnitin
#
# This is a free software; you can distribute and modify under the
# GNU General Public License version 2.
#
# This software is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
####################################################################

=pod

=head1 NAME

B<TLTI> - A simplified interface to Turnitin's LTI gateway

=head1 DESCRIPTION

The LTI gateway accepts SOAP and LTI calls.

=over 4

=item SOAP

The request is a well-formed XML file, and the response is an XML file.
The exact syntax is defined in some WSDL files

=item LTI

Authenticated POST request which calls for some particular page. The
request also specifies whether the response will be shown in a separate
window, or in an IFRAME.

=back

=cut

use strict;
package TLTI;

use Digest::MD5;
use Digest::SHA;
use MIME::Base64 ();
use LWP::UserAgent;
use HTTP::Request::Common;

###################################################################
=pod

=head1 INITIALIZATION

=over 2

=item C<$lti> = TLTI->new(url=>"..",account=>"..",sharedkey=>".." )

Return the initizlized class with the given parameters. The parameters are

=item url => "string"

The URL of the service without trailing slash (/); for example,
   "https://sandbox.turnitin.com"

=item account => "string"

The account identifier (usually a long number).

=item sharedkey => "string"

The shared key agreed with Turnitin; this is used to authenticate all
requests. The key must be strong enough to withdraw guess attacks.

=back

=cut
##################################################################

sub new {
    my($class,%args)=@_;
    my $self = {
       VERSION => "0.1",
       INTEGRATIONCODE => 12,
       baseurl => $args{baseurl},
       account => $args{account},
       secret  => $args{sharedkey},
       LTIURL  => $args{baseurl}."/api/lti/1p0",
       SOAPURL => $args{baseurl}."/api/soap/1p0",
       TEMPLATES => _tii_soap(),
       AGENT     => "Mozilla/5.0",
       TIMEOUT   => 300, # wait that much secs for a reply
    };
    my $err="";
    if(!$args{baseurl} || $args{baseurl} !~ m#^https://.+[^/]$#){
       $err .= "baseurl should be \"https://api.turnitin.com\", \"https://submit.ac.uk\", or \"https://sandbox.turnitin.com\"\n";
    }
    if(!$args{account} ){
       $err .= "account is the account number set by Turnitin\n";
    }
    if(!$args{sharedkey} ){
       $err .= "sharedkey is the joint secret with Turnitin\n";
    }
    die $err if($err);
    bless $self,$class;
    return $self;
}

#################################################################
#
# $urlesceped = TLTI::_urlescape( $string )
#
# replece non-aplhanumeric chars by %dd
#
sub _urlescape {
    my $what = shift;
    return "" if(! defined $what);
    $what =~ s/([^a-zA-Z0-9_\.\-])/sprintf("%%%02X",ord($1))/ges;
    $what;
}
#################################################################
#
# $xmlesceped = TLTI::_xmlescape( $string )
#
# replece characters not allowed in XML by escaping them
#
sub _xmlescape {
    my $what = shift;
    return "" if(!defined $what);
    $what =~ s/([<>&\"\'])/sprintf("\&#%d;",ord($1))/ges;
    $what;
}
##########################################################
#
# $xml_in_hash = TLTI::_make_xml( $D,$xml )
#
# lightweight xml parser
# return a HASH representation of a serialized XML file.
# No attributes and no text nodes between other nodes.
# In case of parsing error, $D->{ERROR} is set
#
sub _make_xml {
    my($D,$text)=@_;
    my $xml={}; my $this=$xml; my $err="";
    foreach my $p (split(/</,$text)){
        next if($p =~ m/^\s*$/ || $p =~ m/^\?/ ); # empty line or start tag
        if($p =~ m/^\/([^\s.]+)>/s){ # </tag> end tag
            if($this->{tag} ne $1){
                $err .= "mismatched closing tag </$1> for opening <$this->{tag}>\n";
            }
            # fall out, close present tag
        } elsif( $p =~ m/^([^\/\s>]+)[^>]*\/>(.*)$/s ){ # <tag />
            my $tag=$1;
            my $new= {tag=>$1, content=>"",parent=>$this};
            $this=$new;
            # fall out, add an empty node
        } elsif( $p =~ m/^([^\/\s>]+)[^>]*>(.*)$/s ){ # <tag ...> content
            my $new = { tag => $1, content=>$2, parent=>$this};
            $this=$new;
            next;
        } else { # error, don't have this tag
            $err .= "cannot parse opening tag <$p\n";
            next;
        }
        # add the node $this to $this->{parent}
        my ($parent,$tag,$content) = ($this->{parent},$this->{tag},$this->{content});
        if(defined $this->{xml}){ $content=$this->{xml}; }
        if(!defined $parent->{xml}){ # not defined yet
            $parent->{xml} = {"$tag" => $content };
        } elsif(!defined $parent->{xml}->{"$tag"}) { # same <tag> occurs more than once
            $parent->{xml}->{"$tag"} = $content;
        } elsif(!defined $parent->{xml}->{"[]$tag"}) { # same <tag> occurs more than once
            $parent->{xml}->{"[]$tag"} =
                 [ $parent->{xml}->{"$tag"}, $content ];
        } else {
            push @{$parent->{xml}->{"[]$tag"}}, $content;
        }
        $this=$parent;
    }
    while(defined $this->{parent}){
        $err .= "tag <$this->{tag}> is not closed\n";
        $this=$this->{parent};
    }
    if($err){$D->{ERROR}=3; $D->{errormsg}=$err; $D->{rawxml}=$text; }
    return $this->{xml};
}

##########################################################################
#
# extract the response from the response. Return the hash $D
#  $D->{ERROR} = 1: no response received
#  $D->{ERROR} = 3: error in parsing the received xml
#    otherwise: {httpcpde}= code
#               {status}  = status from the message, if parsed
#               {message} = response description, if parsed
#     {xxx} other message specific fields (see the templates)
#
sub _extract_xml_response {
    my($res,$template)=@_;
    my $D={ ERROR => 0 };
    if($res){
        $D->{httpcode} = $res->code;
        my $r=""; $r=$res->content if($res->is_success);
        if(defined $template->{xmlresponse}){
            # let this routine make the dirty work
            my $xml=_make_xml($D,$r);
            if(! $D->{ERROR} && $xml){
                &{$template->{xmlresponse}}($D,$xml);
            }
        } else {
          #parse $r, this part relies on nicely formatted xml
          my $itemlist = $template->{response};
          $itemlist=[] if(!defined $itemlist);
          for my $l(split('\n',$r)){ # go over lines in the response
            if( $l=~/<tns:imsx_codeMajor>([^<]*)<\// ){
                  $D->{status} = $1; ## success/failure
            }
            if( $l=~/<tns:imsx_description>(.*)$/ ){
                  $D->{message} = $1; ## description
                  $D->{message} =~ s/<\/.*$//;
            }
            foreach my $tag(@$itemlist){
               if( $l =~ /<$tag>([^<]*)<\// ){
                    $D->{$tag}=$1;
               }
            }
          }
        }
    } else { # didn't receive data
        $D->{ERROR} = 1;
        $D->{errormsg} = "No data was received\n";
    }
}

#########################################################################
#
# $authstring = $tlti->oauth_signature($url,$params)
#
# generates OAUTH signature using a POST method
#    $params->{oauth_signature} is the signature;
#   returns the Authorization string composed from all oauth fields
#
sub oauth_signature { # method = "POST"
    my($class,$url,$params)=@_;
    $params->{lang}="en_us"; # sorry, this one only
    $params->{oauth_nonce} = Digest::SHA::sha1_hex( sprintf(
        "48 random bits: %06x%06x",rand(0xfffff0),rand(0xfffff0)));
    $params->{oauth_timestamp} = time();
    $params->{oauth_consumer_key} = $class->{account};
    $params->{oauth_signature_method} = "HMAC-SHA1";
    $params->{oauth_version} = "1.0";
    my $arg="";
    foreach my $key(sort keys %$params){
        $arg .= ($arg?'&':'')._urlescape2($key).'='._urlescape2($params->{$key});
    }
    my $oauthsig=MIME::Base64::encode(Digest::SHA::hmac_sha1(
         "POST\&"._urlescape2($url)."&"._urlescape2($arg),
         _urlescape2($class->{secret}).'&'));
    chomp($oauthsig); $params->{oauth_signature}=$oauthsig;
    my $result="OAuth ";
    foreach my $key(keys %$params){
         next if($key !~ /^oauth_/ );
         $result .= "$key=\""._urlescape2($params->{$key}) . "\", ";
    }
    $result =~ s/, $//;
    return $result;
}

#############################################################
=pod

=head1 Sending/receiving SOAP requests

Usage:
   $response=$tlti->soap_request("function",arg1=>"..", ...)

"function" is the function to be called (see below); $response 
is a hash containing the response values:
 $response->{ERROR} = 0 for no error, otherwise it is non-zero,
 $response->{httpcode} is the http code (typically 200)
 $response->{status} is the status code
 $response->{message} is verbal status information

The following functions and arguments are available:

=over 2

=item ("createPerson", firstname=>"First",lastname=>"Last",
         email=>"addr@univ.edu", role=>"Instructor")

$response->{'tns:sourcedId'} the id of the newly created person record. 
Role can also be "Learner".

=item ("discoverPerson", email=>"address@university.edu")

$response->{'tns:sourcedId'} the id of the person with the given address.

=item ("readPerson",personid=>0123456)

Returned values from the person's record: email, first, last, role, and
eula. The last value indicates whether the person accepted the End User 
License Agreement.

=item ("createCourse},coursetitle=>"Course Title", enddate=>"I<date>")

Create a course with the given title and given end date, which should be
given in the form "2015-01-31T02:00:59Z". 
$response->{'tns:sourcedId'} is the id of the newly created course.

=item ("readCourse" courseid=>123456)

Returns course end date and course title in fields $response->{'tns:end'} 
and $respons->{'tns:textString'}, respectively.

=item ("createAssignment",courseid=>012345,label=>"Title", startdate=>"I<date>",duedate=>"I<date>",feedbackdate=>"I<date>")

All date should be of the format as above.
$response->{'tns:sourcedId'} is the id of the new assignment. Several
submission parameters are set with default values, such as MaxGrade=100.
For details, see the source.

=item ("enroll", courseid=>0123456, personid=>6543321, role=>"Learner")

Enrolls the person in the course. When role=>"Instructor", adds the person
as a teacher to the course. 
$response->{'tns:sourcedId'} is the id of the returned I<membership> record.

=item ("readReport", submissionid=>0123456)

$response->{score} is the similarity score, or empty if score is not avaiable yet.

=item ("deleteSubmission", submissionid=>123456)

delete the given submission from the "submission" listing of the course. 
For success, check whether $response->{status} is 'success'.

=back

=cut
############################################################
sub soap_request {
    my($self,$tp,%args)=@_;
    my $template = $self->{TEMPLATES}->{$tp};
    my $url = $self->{SOAPURL}."/".$template->{url};
    my $body = $template->{xml};
    my $data={}; foreach my $k(keys %args){$data->{$k}=$args{$k};}
    if(!defined $data->{messageid}){
        $data->{messageid}=sprintf("34%06x-abcd-4321-8765-1cedda%06x",
             rand(0xfffff0),rand(0xfffff0));
    }
    foreach my $key(@{$template->{args}}){
        $body =~ s/%%$key%%/_xmlescape($data->{$key})/eg;
    }
    my $bodyhash=MIME::Base64::encode(Digest::SHA::sha1($body));
    chomp $bodyhash;
    my $oauthsig=$self->oauth_signature($url,{oauth_body_hash=>$bodyhash});
    my $s=LWP::UserAgent->new(agent=>$self->{AGENT},timeout=>$self->{TIMEOUT});
    return _extract_xml_response(
       $s->request(POST $url."?lang=en_us",
          Content_Type => 'text/xml;charset="utf-8"',
          Cache_control => 'no-cache',
          Pragma        => 'no-cache',
          SOAPAction    => '"' . $template->{soap} . '"',
          Source        => $self->{INTEGRATIONCODE},
          Authorization => $oauthsig,
          Content       => $body ),
       $template);
}

#########################################################################
#
# $tlti->lti_request_params($url,$params)
#
#  
#
sub lti_request_params {
    my($self,$url,$params)=@_;
    $params->{lti_message_type} = 'basic-lti-launch-request';
    $params->{lti_version} = 'LTI-1p0';
    $params->{custom_source} = $self->{INTEGRATIONCODE};
    $params->{resource_link_id}=sprintf("bb%06x-5e90-4667-8582-aaff1f%06x",
                  rand(0xfffff0),rand(0xfffff0));
    $self->oauth_signature($url,$params);
}

#########################################################################
=pod

=head1 LTI redirections

Usage:
   $tlti->lti_redirect("lti-url",arg1=>"..", ...)

Prints out on STDOUT a full HTML authenticated response, including headers,
which redirects to the requested LTI service.

Some examples:

=over 2

=item  "dv/report", lis_result_sourcedid=>"I<subid>", lis_person_sourcedid=>"I<personid>", roles=>"Instructor"

Show the report page for submission I<subid> viewing by person I<personid>.

=item  "assignment/inbox",lis_person_sourcedid=>"I<personid>", roles=>"Instructor", lis_lineitem_sourcedid=>I<assignid>

Show all submissions in the assignment I<assignid>.

=item  "user/eula", lis_person_sourcedid=>"I<personid>", roles=>"Instructor" 

Redirect to the End User License Agreement page for teacher I<personid>.

=back

=cut
#########################################################################
sub lti_redirect {
    my($self,$url,%args)=@_;
    my $params={}; foreach my $k(keys %args){$params->{$k}=$args{$k};}
    $url = $self->{LTIURL}."/$url";
    $self->lti_request_params($url,$params);
    $url=_xmlescape($url);
    print <<HEADER;
Content-Type: text/html;charset=utf-8
Pragma: no-cache
Cache-Control: no-cache

<html>
<body onload="document.getElementById('TT').submit()">
<form id="TT" name="TT" action="$url" method="POST" enctype="application/x-www-form-urlencoded">
HEADER
    foreach my $key(keys %$params){
         print "<input type=\"hidden\" name=\"$key\" value=\"",
              _xmlescape($params->{$key}),"\">\n";
    }
    print <<TAILER;
<noscript>
This page is moved <input type="submit" value="here">.
</noscript>
</form>
</body></html>


TAILER
}
##########################################################################
=pod

=head1 Submit/resubmit a pdf file for similairty checking

Usage for submission: 
  $response = $tlti->lti_submit(I<full_path_of_pdf>, title=> "Title", teacher=>I<tid>, student=>I<sid>, assigid=>I<assid>)

Usage for resubmitting:
  $response = $tlti->lti_submit(I<full_path_of_pdf>, title=> "Title", teacher=>I<tid>, student=>I<sid>, submissionid=>I<smsid>)

The $response is a hash containing the following fields:
  $response->{ERROR} = 0 for no error, otherwise it is non-zero;
  $response->{status} = 'success' if submission was accepted;
  $response->{lis_resuld_sourcedid} the id of the submission,

=cut
#########################################################################
sub lti_submit {
    my($self,$file,%args)=@_;
    my $params = {
       custom_xmlresponse => 1,
       lis_person_sourcedid => $args{teacher},
       roles=>'Instructor',
       custom_submission_title => substr(($args{title} || "Untitled"),0,95),
       custom_submission_author => $args{student},
    };
    my $url="";
    if($args{assigid}){
        $params->{lis_lineitem_sourcedid}=$args{assigid};
        $url="upload/submit";
    } else {
        $params->{lis_result_sourcedid}= $args{submissionid}||1234;
        $url="upload/resubmit";
    }
    $url = $self->{LTIURL}."/$url";
    $self->lti_request_params($url,$params);
    $params->{custom_submission_data} = [
        $file,
        "submission.pdf",
        Content_Type => "application/pdf",
        Content_Transfer_Encoding => 'base64',
    ];
    my $s=LWP::UserAgent->new(agent=>$self->{AGENT},timeout=>$self->{TIMEOUT});
    return  _extract_xml_response(
        $s->request(POST $url,
            Content_Type => 'form-data',
            Content_Transder_Encoding => '8bit',
            Content => $params ),
        {response=>["status","message","lis_result_sourcedid"]});
}

####################################################################
#
# $template = _tii_soap()
#
# templates for the soap requests
#
sub _tii_soap {
return {    
    createPerson => {# create a person which does not exist
       url => "lis-person",
       soap => "http://www.imsglobal.org/soap/lis/pms2p0/createByProxyPerson",
       args => ["messageid","firstname","lastname","email","role"],
              ## role: Instructor/Learner
       response => ["tns:sourcedId"],
       xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/pms2p0/wsdl11/sync/imspms_v2p0"><SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
  <ns1:imsx_version>V1.0</ns1:imsx_version>
  <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:createByProxyPersonRequest>
 <ns1:personRecord><ns1:sourcedGUID><ns1:sourcedId/></ns1:sourcedGUID><ns1:person><ns1:name><ns1:nameType><ns1:instanceIdentifier><ns1:language>en-US</ns1:language><ns1:textString>1</ns1:textString></ns1:instanceIdentifier><ns1:instanceVocabulary>http://www.imsglobal.org/vdex/lis/pmsv2p0/nametypevocabularyv1p0.xml</ns1:instanceVocabulary><ns1:instanceValue><ns1:language>en-US</ns1:language><ns1:textString>Contact</ns1:textString></ns1:instanceValue></ns1:nameType>
 <ns1:partName><ns1:instanceIdentifier><ns1:language>en-US</ns1:language><ns1:textString>1</ns1:textString></ns1:instanceIdentifier><ns1:instanceVocabulary>http://www.imsglobal.org/vdex/lis/pmsv2p0/partnamevocabularyv1p0.xml</ns1:instanceVocabulary><ns1:instanceName><ns1:language>en-US</ns1:language><ns1:textString>First</ns1:textString></ns1:instanceName><ns1:instanceValue><ns1:language>en-US</ns1:language><ns1:textString>%%firstname%%</ns1:textString></ns1:instanceValue></ns1:partName>
 <ns1:partName><ns1:instanceIdentifier><ns1:language>en-US</ns1:language><ns1:textString>2</ns1:textString></ns1:instanceIdentifier><ns1:instanceVocabulary>http://www.imsglobal.org/vdex/lis/pmsv2p0/partnamevocabularyv1p0.xml</ns1:instanceVocabulary><ns1:instanceName><ns1:language>en-US</ns1:language><ns1:textString>Last</ns1:textString></ns1:instanceName><ns1:instanceValue><ns1:language>en-US</ns1:language><ns1:textString>%%lastname%%</ns1:textString></ns1:instanceValue></ns1:partName></ns1:name>
 <ns1:contactinfo><ns1:contactinfoType><ns1:instanceIdentifier><ns1:language>en-US</ns1:language><ns1:textString>1</ns1:textString></ns1:instanceIdentifier><ns1:instanceVocabulary>http://www.imsglobal.org/vdex/lis/pmsv2p0/contactinfotypevocabularyv1p0.xml</ns1:instanceVocabulary><ns1:instanceValue><ns1:language>en-US</ns1:language><ns1:textString>EmailWorkPrimary</ns1:textString></ns1:instanceValue></ns1:contactinfoType><ns1:contactinfoValue><ns1:language>en-US</ns1:language><ns1:textString>%%email%%</ns1:textString></ns1:contactinfoValue></ns1:contactinfo>
 <ns1:roles><ns1:enterpriserolesType><ns1:instanceIdentifier><ns1:language>en-US</ns1:language><ns1:textString>1</ns1:textString></ns1:instanceIdentifier><ns1:instanceVocabulary>http://www.imsglobal.org/vdex/lis/pmsv2p0/epriserolestypevocabularyv1p0.xml</ns1:instanceVocabulary><ns1:instanceName><ns1:language>en-US</ns1:language><ns1:textString>Other</ns1:textString></ns1:instanceName><ns1:instanceValue><ns1:language>en-US</ns1:language><ns1:textString>Other</ns1:textString></ns1:instanceValue></ns1:enterpriserolesType>
     <ns1:institutionRole><ns1:institutionroletype><ns1:instanceIdentifier><ns1:language>en-US</ns1:language><ns1:textString>1</ns1:textString></ns1:instanceIdentifier><ns1:instanceVocabulary>http://www.imsglobal.org/vdex/lis/pmsv2p0/institutionroletypevocabularyv1p0.xml</ns1:instanceVocabulary><ns1:instanceValue><ns1:language>en-US</ns1:language><ns1:textString>%%role%%</ns1:textString></ns1:instanceValue></ns1:institutionroletype><ns1:primaryroletype>true</ns1:primaryroletype></ns1:institutionRole>
 </ns1:roles></ns1:person></ns1:personRecord>
</ns1:createByProxyPersonRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    discoverPerson => { #discover a person by e-mail address
      url => "lis-person",
      soap => "http://www.imsglobal.org/soap/lis/pms2p0/discoverPersonIds",
      args => ["messageid","email"],
      response => ["tns:sourcedId"],
      xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/pms2p0/wsdl11/sync/imspms_v2p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
    <ns1:imsx_version>V1.0</ns1:imsx_version>
      <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:discoverPersonIdsRequest>
  <ns1:queryObject>%%email%%</ns1:queryObject>
</ns1:discoverPersonIdsRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    readPerson => { ## read all data of a person
        url => "lis-person",
        soap => "http://www.imsglobal.org/soap/lis/pms2p0/readPerson",
        args => ["messageid","personid"],
        xmlresponse => \&_readPersonXml,
        xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/pms2p0/wsdl11/sync/imspms_v2p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
 <ns1:imsx_version>V1.0</ns1:imsx_version><ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:readPersonRequest><ns1:sourcedId>%%personid%%</ns1:sourcedId></ns1:readPersonRequest>
</SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    createCourse => { # createByProxyCourseSection
       url => "lis-coursesection",
       soap => "http://www.imsglobal.org/soap/lis/cmsv1p0/createByProxyCourseSection",
       args => ["messageid","coursetitle","enddate"],
       response => ["tns:sourcedId"], ## Id of the new course
       xml => <<XML,
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/cmsv1p0/wsdl11/sync/imscms_v1p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
 <ns1:imsx_version>V1.0</ns1:imsx_version>
 <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:createByProxyCourseSectionRequest>
 <ns1:courseSectionRecord><ns1:sourcedGUID><ns1:sourcedId/></ns1:sourcedGUID>
<ns1:courseSection>
  <ns1:title><ns1:language>en-US</ns1:language><ns1:textString>%%coursetitle%%</ns1:textString></ns1:title>
  <ns1:timeFrame><ns1:end>%%enddate%%</ns1:end></ns1:timeFrame>
</ns1:courseSection></ns1:courseSectionRecord>
</ns1:createByProxyCourseSectionRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    readCourse => { ## courseSection
       url => "lis-coursesection",
       soap => "http://www.imsglobal.org/soap/lis/cmsv1p0/readCourseSection",
       args => ["messageid","courseid"],
       response => ["tns:end","tns:textString"], #  enddate, title
       xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/cmsv1p0/wsdl11/sync/imscms_v1p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
 <ns1:imsx_version>V1.0</ns1:imsx_version>
 <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:readCourseSectionRequest><ns1:sourcedId>%%courseid%%</ns1:sourcedId></ns1:readCourseSectionRequest>
</SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    createAssignment => { #createByProxyLineItemRequest
       url => "lis-lineitem",
       soap => "http://www.imsglobal.org/soap/lis/oms1p0/createByProxyLineItem",
       args => ["messageid","courseid","label","startdate","duedate",
            "feedbackdate"],  ## date format: 2014-01-027T15:56:00Z
       response => ["tns:sourcedId"],
## default values:
## AuthorOriginalityAccess // Author can see report => no
## SubmittedDocumentCheck (checked against database) => yes
## InternetCheck (checked against internet source) => yes
## PublicationsCheck (against publication sources database) => yes
## MaxGrade => 100
## LateSubmissionAllowed => yes
## SubmitPapersto => 1 (Standard repository, 0: nowhere, 2: institution)
## ResubmissionRule => 1 (generate report, but can resubmit later)
## BibliographyExcluded => no
## SmallMathcExcluded => 0 (don't exclude, 1: word count, 2: percentage)
## SmallMatchExclusionThreshold => 0
## AnonymousMarking => no
## Erater => no
## TranslatedMatching => no
## AllowNonOrSubmissions => no (all submissions generate report)
       xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/oms1p0/wsdl11/sync/imsoms_v1p0"><SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
 <ns1:imsx_version>V1.0</ns1:imsx_version>
 <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:createByProxyLineItemRequest>
 <ns1:lineItemRecord><ns1:sourcedGUID><ns1:sourcedId/></ns1:sourcedGUID><ns1:lineItem>
 <ns1:context><ns1:contextIdentifier>%%courseid%%</ns1:contextIdentifier><ns1:contextType>courseSection</ns1:contextType></ns1:context>
 <ns1:label>%%label%%</ns1:label>
 <ns1:extension><ns1:extensionNameVocabulary>http://www.turnitin.com/static/source/media/turnitinvocabularyv1p0.xml</ns1:extensionNameVocabulary><ns1:extensionValueVocabulary>http://www.imsglobal.org/vdex/lis/omsv1p0/extensionvocabularyv1p0.xml</ns1:extensionValueVocabulary>
  <ns1:extensionField><ns1:fieldName>StartDate</ns1:fieldName><ns1:fieldType>DateTime</ns1:fieldType><ns1:fieldValue>%%startdate%%</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>DueDate</ns1:fieldName><ns1:fieldType>DateTime</ns1:fieldType><ns1:fieldValue>%%duedate%%</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>FeedbackReleaseDate</ns1:fieldName><ns1:fieldType>DateTime</ns1:fieldType><ns1:fieldValue>%%feedbackdate%%</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>AuthorOriginalityAccess</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>RubricId</ns1:fieldName><ns1:fieldType>Integer</ns1:fieldType><ns1:fieldValue></ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>SubmittedDocumentsCheck</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>1</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>InternetCheck</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>1</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>PublicationsCheck</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>1</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>MaxGrade</ns1:fieldName><ns1:fieldType>Integer</ns1:fieldType><ns1:fieldValue>100</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>LateSubmissionsAllowed</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>1</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>SubmitPapersTo</ns1:fieldName><ns1:fieldType>Integer</ns1:fieldType><ns1:fieldValue>1</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>ResubmissionRule</ns1:fieldName><ns1:fieldType>Integer</ns1:fieldType><ns1:fieldValue>1</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>BibliographyExcluded</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>QuotedExcluded</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>SmallMatchExclusionType</ns1:fieldName><ns1:fieldType>Integer</ns1:fieldType><ns1:fieldValue>1</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>SmallMatchExclusionThreshold</ns1:fieldName><ns1:fieldType>Integer</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>AnonymousMarking</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>Erater</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>EraterSpelling</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>EraterGrammar</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>EraterUsage</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>EraterMechanics</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>EraterStyle</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>EraterSpellingDictionary</ns1:fieldName><ns1:fieldType>String</ns1:fieldType><ns1:fieldValue>en_US</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>EraterHandbook</ns1:fieldName><ns1:fieldType>Integer</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>TranslatedMatching</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
  <ns1:extensionField><ns1:fieldName>AllowNonOrSubmissions</ns1:fieldName><ns1:fieldType>Boolean</ns1:fieldType><ns1:fieldValue>0</ns1:fieldValue></ns1:extensionField>
</ns1:extension></ns1:lineItem></ns1:lineItemRecord></ns1:createByProxyLineItemRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    addMember => { ## createByProxyMembership, add a member to a class
       url => "lis-membership",
       soap => "http://www.imsglobal.org/soap/lis/mms2p0/createByProxyMembership",
       args => ["messageid","courseid","personid","role"], ## Instructor/Learner
       response=>["tns:sourcedId"], # membership record
       xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/mms2p0/wsdl11/sync/imsmms_v2p0" xmlns:ns2="http://www.imsglobal.org/services/lis/oms1p0/wsdl11/sync/imsoms_v1p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
  <ns1:imsx_version>V1.0</ns1:imsx_version>
  <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:createByProxyMembershipRequest><ns1:membershipRecord><ns1:sourcedGUID><ns1:sourcedId/></ns1:sourcedGUID>
 <ns1:membership><ns1:collectionSourcedId>%%courseid%%</ns1:collectionSourcedId><ns1:membershipIdType>courseSection</ns1:membershipIdType>
 <ns1:member><ns1:personSourcedId>%%personid%%</ns1:personSourcedId><ns1:role><ns1:roleType>%%role%%</ns1:roleType></ns1:role></ns1:member></ns1:membership></ns1:membershipRecord>
</ns1:createByProxyMembershipRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    readReport => { ## check the score of a submitted paper
      url => "lis-result",
      soap => "http://www.imsglobal.org/soap/lis/oms1p0/readResult",
      args => ["messageid","submissionid"],
      xmlresponse => \&_readReportXml,
      xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/oms1p0/wsdl11/sync/imsoms_v1p0">
 <SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
    <ns1:imsx_version>V1.0</ns1:imsx_version>
    <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
 </ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:readResultRequest><ns1:sourcedId>%%submissionid%%</ns1:sourcedId></ns1:readResultRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    deleteSubmission => { # deleteResult
       url => "lis-result",
       soap => "http://www.imsglobal.org/soap/lis/oms1p0/deleteResult",
       args => ["messageid","submissionid"],
       response => [], ## no response
       xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/oms1p0/wsdl11/sync/imsoms_v1p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
    <ns1:imsx_version>V1.0</ns1:imsx_version>
    <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo>
</SOAP-ENV:Header><SOAP-ENV:Body><ns1:deleteResultRequest>
  <ns1:sourcedId>%%submissionid%%</ns1:sourcedId>
</ns1:deleteResultRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

####################################################
## not used
####################################################

    deleteAssignment => { # deleteLineItem
       url => "lis-lineitem",
       soap => "http://www.imsglobal.org/soap/lis/oms1p0/deleteLineItem",
       args => ["messageid","assid"],
       response => ["tns:sourcedId"], ##
       xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/oms1p0/wsdl11/sync/imsoms_v1p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
 <ns1:imsx_version>V1.0</ns1:imsx_version>
 <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header>
<SOAP-ENV:Body><ns1:deleteLineItemRequest>
 <ns1:sourcedId>%%assid%%</ns1:sourcedId>
</ns1:deleteLineItemRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    readAssignment => { ## read info about an assignment
       url => "lis-lineitem",
       soap => "http://www.imsglobal.org/soap/lis/oms1p0/readLineItem",
       args => ["messageid","assid"],
       xml => <<XML,
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/oms1p0/wsdl11/sync/imsoms_v1p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
 <ns1:imsx_version>V1.0</ns1:imsx_version>
 <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier></ns1:imsx_syncRequestHeaderInfo>
</SOAP-ENV:Header><SOAP-ENV:Body>
  <ns1:readLineItemRequest><ns1:sourcedId>%%assid%%</ns1:sourcedId>
</ns1:readLineItemRequest></SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

    discoverResult => { ## assigments in a class
       url => "lis-result",
       soap => "http://www.imsglobal.org/soap/lis/oms1p0/discoverResultIds",
       args => ["messageid","assid"], ## no datefrom
       xml => <<XML,
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="http://www.imsglobal.org/services/lis/oms1p0/wsdl11/sync/imsoms_v1p0">
<SOAP-ENV:Header><ns1:imsx_syncRequestHeaderInfo>
 <ns1:imsx_version>V1.0</ns1:imsx_version>
 <ns1:imsx_messageIdentifier>%%messageid%%</ns1:imsx_messageIdentifier>
</ns1:imsx_syncRequestHeaderInfo></SOAP-ENV:Header><SOAP-ENV:Body>
  <ns1:discoverResultIdsRequest><ns1:queryObject>{"lineitem_sourcedid":"%%assid%%","date_from":null}</ns1:queryObject></ns1:discoverResultIdsRequest>
</SOAP-ENV:Body></SOAP-ENV:Envelope>
XML
    },

};}

sub _readReportXml {
    my ($D,$xml)=@_; $xml=$xml->{'SOAP-ENV:Envelope'};
    my $hdr=$xml->{'SOAP-ENV:Header'}
        ->{'tns:imsx_syncResponseHeaderInfo'}
        ->{'tns:imsx_statusInfo'};
    $D->{status} = $hdr->{'tns:imsx_codeMajor'}; # success, failure
    $D->{message} = $hdr->{'ns:imsx_description'};
    if($hdr->{'tns:imsx_codeMajor'} eq "success" &&
        $hdr->{'tns:imsx_description'} eq 'Object Result found.'){
        $xml=$xml->{'SOAP-ENV:Body'}->{'tns:readResultResponse'}->
           {'tns:resultRecord'}->{'tns:result'};
        $D->{score}=$xml->{'tns:resultScore'}->{'tns:textString'};
        $D->{teacher}=$xml->{'tns:personSourcedId'};
        $D->{title}=$xml->{'tns:resultValue'}->{'tns:label'};
        $D->{assid}=$xml->{'tns:lineItemSourcedId'};
    }
}

sub _readPersonXml {
    my ($D,$xml)=@_; $xml=$xml->{'SOAP-ENV:Envelope'};
    my $hdr=$xml->{'SOAP-ENV:Header'}
        ->{'tns:imsx_syncResponseHeaderInfo'}
        ->{'tns:imsx_statusInfo'};
    $D->{status} = $hdr->{'tns:imsx_codeMajor'}; # success, failure
    $D->{message} = $hdr->{'tns:imsx_description'};
    if($hdr->{'tns:imsx_codeMajor'} eq "success" &&
        $hdr->{'tns:imsx_description'} eq 'User Found'){
        $xml=$xml->{'SOAP-ENV:Body'}->{'tns:readPersonResponse'}->
           {'tns:personRecord'}->{'tns:person'};
        $D->{email}=$xml->{'tns:contactinfo'}->{'tns:contactinfoValue'}
                ->{'tns:textString'};
        $D->{role}=$xml->{'tns:roles'}->{'tns:institutionRole'}
                 ->{'tns:institutionroletype'}->{'tns:instanceValue'}->{'tns:textString'};
        foreach my $t(@{$xml->{'tns:extension'}->{'[]tns:extensionField'}}){
            if($t->{'tns:fieldName'} eq 'AcceptedUserAgreement'){
                $D->{eula}=$t->{'tns:fieldValue'};
            }
        }
        foreach my $t(@{$xml->{'tns:name'}->{'[]tns:partName'}}){
            if($t->{'tns:instanceName'}->{'tns:textString'} eq 'First'){
                $D->{first} = $t->{'tns:instanceValue'}->{'tns:textString'};
            }
            if($t->{'tns:instanceName'}->{'tns:textString'} eq 'Last'){
                $D->{last} = $t->{'tns:instanceValue'}->{'tns:textString'};
            }
        }
    }
}
##########################################################################
=pod

=head1 AUTHOR

Laszlo Csirmaz, E<lt>csirmaz@ceu.huE<gt>

=head1 DATE

20-Dec-2014

=cut
##########################################################################


1;

__END__