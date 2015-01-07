turnitin-lti-perl
=================

Perl interface to access Turnitin LTI services

    The LTI gateway accepts SOAP and LTI calls.

    SOAP
        The request is a well-formed XML file, and the response is an XML
        file. The exact syntax is defined in some WSDL files

    LTI Authenticated POST request which calls for some particular page. The
        request also specifies whether the response will be shown in a
        separate window, or in an IFRAME.

INITIALIZATION

    $lti = TLTI->new(url=>"..", account=>"..", sharedkey=>".." )
      Return the initizlized class with the given parameters. The parameters
      are
    url => "string"
      The URL of the service without trailing slash (/); for example,
      "https://sandbox.turnitin.com"
    account => "string"
      The account identifier (usually a long number).
    sharedkey => "string"
      The shared key agreed with Turnitin; this is used to authenticate all
      requests. The key must be strong enough to withdraw guess attacks.

Sending/receiving SOAP requests

    Usage: $response=$tlti->soap_request("function", arg1=>"..", ...)

    "function" is the function to be called (see below); $response is a hash
    containing the response values: $response->{ERROR} = 0 for no error,
    otherwise it is non-zero, $response->{httpcode} is the http code
    (typically 200) $response->{status} is the status code
    $response->{message} is verbal status information

    The following functions and arguments are available:

    ("createPerson", firstname=>"First", lastname=>"Last",
        email=>"addr@univ.edu", role=>"Instructor")
      $response->{'tns:sourcedId'} the id of the newly created person
      record. Role can also be "Learner".

    ("discoverPerson", email=>"address@university.edu")
      $response->{'tns:sourcedId'} the id of the person with the given
      address.

    ("readPerson", personid=>0123456)
      Returned values from the person's record: email, first, last, role,
      and eula. The last value indicates whether the person accepted the End
      User License Agreement.

    ("createCourse", coursetitle=>"Course Title", enddate=>"*date*")
      Create a course with the given title and given end date, which should
      be given in the form "2015-01-31T02:00:59Z".
      $response->{'tns:sourcedId'} is the id of the newly created course.

    ("readCourse", courseid=>123456)
      Returns course end date and course title in fields
      $response->{'tns:end'} and $respons->{'tns:textString'}, respectively.

    ("createAssignment", courseid=>012345, label=>"Title",
        startdate=>"*date*", duedate=>"*date*", feedbackdate=>"*date*")
      All date should be of the format as above.
      $response->{'tns:sourcedId'} is the id of the new assignment. Several
      submission parameters are set with default values, such as
      MaxGrade=100. For details, see the source.

    ("enroll", courseid=>0123456, personid=>6543321, role=>"Learner")
      Enrolls the person in the course. When role=>"Instructor", adds the
      person as a teacher to the course. $response->{'tns:sourcedId'} is the
      id of the returned *membership* record.

    ("readReport", submissionid=>0123456)
      $response->{score} is the similarity score, or empty if score is not
      avaiable yet.

    ("deleteSubmission", submissionid=>123456)
      delete the given submission from the "submission" listing of the
      course. For success, check whether $response->{status} is 'success'.

LTI redirections

    Usage: $tlti->lti_redirect(*lti-url*, arg1=>"..", ...)

    Prints out on STDOUT a full HTML authenticated response, including
    headers, which redirects to the requested LTI service.

    Some examples:

    ("dv/report", lis_result_sourcedid=>*subid*,
        lis_person_sourcedid=>*personid*, roles=>"Instructor")
      Show the report page for submission *subid* viewing by person
      *personid* as an Instructor.

    ("assignment/inbox", lis_person_sourcedid=>*personid*,
        roles=>"Instructor", lis_lineitem_sourcedid=>*assignid*)
      Show all submissions in the assignment *assignid*.

    ("user/eula", lis_person_sourcedid=>*personid*, roles=>"Instructor")
      Redirect to the End User License Agreement page for teacher
      *personid*.

Submit/resubmit a pdf file for similairty checking

    Usage for submission: 
    $response = $tlti->lti_submit(*full_path_of_pdf*, title=>"Title", 
        teacher=>*tid*, student=>*sid*, assignid=>*assid*)

    Usage for resubmitting:
    $response = $tlti->lti_submit(*full_path_of_pdf*, title=> "Title", 
        teacher=>*tid*, student=>*sid*, submissionid=>*smsid*)

    The $response is a hash containing the following fields:
    $response->{ERROR} = 0 for no error, otherwise it is non-zero;
    $response->{status} = 'success' if submission was accepted;
    $response->{lis_resuld_sourcedid} the id of the submission,

AUTHOR

    Laszlo Csirmaz, <csirmaz@ceu.hu>

DATE

    20-Dec-2014

