###
# Amalgamated package for httpd
# Do not edit directly, tweak the source in src/ and rerun
# build.tcl
###
package require Tcl 8.6
package provide httpd 4.2.0
namespace eval ::httpd {}
set ::httpd::version 4.2.0

###
# START: core.tcl
###
###
# Author: Sean Woods, yoda@etoyoc.com
##
# Adapted from the "minihttpd.tcl" file distributed with Tclhttpd
#
# The working elements have been updated to operate as a TclOO object
# running with Tcl 8.6+. Global variables and hard coded tables are
# now resident with the object, allowing this server to be more easily
# embedded another program, as well as be adapted and extended to
# support the SCGI module
###

package require uri
package require dns
package require cron
package require coroutine
package require tool
package require mime
package require fileutil
package require websocket
package require Markdown
package require uuid
package require fileutil::magic::filetype
namespace eval httpd::content {}

namespace eval ::url {}
namespace eval ::httpd {}
namespace eval ::scgi {}

tool::define ::httpd::mime {


  method html::header {{title {}} args} {
    set result {}
    append result "<HTML><HEAD>"
    if {$title ne {}} {
      append result "<TITLE>$title</TITLE>"
    }
    append result "<link rel=\"stylesheet\" href=\"/style.css\">"
    append result "</HEAD><BODY>"
    return $result
  }
  method html::footer {args} {
    return "</BODY></HTML>"
  }

  method http_code_string code {
    set codes {
      200 {Data follows}
      204 {No Content}
      301 {Moved Permanently}
      302 {Found}
      303 {Moved Temporarily}
      304 {Not Modified}
      307 {Moved Permanently}
      308 {Moved Temporarily}
      400 {Bad Request}
      401 {Authorization Required}
      403 {Permission denied}
      404 {Not Found}
      408 {Request Timeout}
      411 {Length Required}
      419 {Expectation Failed}
      500 {Server Internal Error}
      501 {Server Busy}
      503 {Service Unavailable}
      504 {Service Temporarily Unavailable}
      505 {HTTP Version Not Supported}
    }
    if {[dict exists $codes $code]} {
      return [dict get $codes $code]
    }
    return {Unknown Http Code}
  }

  method HttpHeaders {sock {debug {}}} {
    set result {}
    set LIMIT 8192
    ###
    # Set up a channel event to stream the data from the socket line by
    # line. When a blank line is read, the HttpHeaderLine method will send
    # a flag which will terminate the vwait.
    #
    # We do this rather than entering blocking mode to prevent the process
    # from locking up if it's starved for input. (Or in the case of the test
    # suite, when we are opening a blocking channel on the other side of the
    # socket back to ourselves.)
    ###
    chan configure $sock -translation {auto crlf} -blocking 0 -buffering line
    while 1 {
      set readCount [::coroutine::util::gets_safety $sock 4096 line]
      if {$readCount==0} break
      append result $line \n
      if {[string length $result] > $LIMIT} {
        error {Headers too large}
      }
    }
    ###
    # Return our buffer
    ###
    return $result
  }

  method HttpHeaders_Default {} {
    return {Status {200 OK}
Content-Size 0
Content-Type {text/html; charset=UTF-8}
Cache-Control {no-cache}
Connection close}
  }

  ###
  # Minimalist MIME Header Parser
  ###
  method MimeParse mimetext {
    set data(mimeorder) {}
    foreach line [split $mimetext \n] {
      # This regexp picks up
      # key: value
      # MIME headers.  MIME headers may be continue with a line
      # that starts with spaces or a tab
      if {[string length [string trim $line]]==0} break
      if {[regexp {^([^ :]+):[ 	]*(.*)} $line dummy key value]} {
        # The following allows something to
        # recreate the headers exactly
        lappend data(headerlist) $key $value
        # The rest of this makes it easier to pick out
        # headers from the data(mime,headername) array
        #set key [string tolower $key]
        if {[info exists data(mime,$key)]} {
          append data(mime,$key) ,$value
        } else {
          set data(mime,$key) $value
          lappend data(mimeorder) $key
        }
        set data(key) $key
      } elseif {[regexp {^[ 	]+(.*)}  $line dummy value]} {
        # Are there really continuation lines in the spec?
        if {[info exists data(key)]} {
          append data(mime,$data(key)) " " $value
        } else {
          error "INVALID HTTP HEADER FORMAT: $line"
        }
      } else {
        error "INVALID HTTP HEADER FORMAT: $line"
      }
    }
    ###
    # To make life easier for our SCGI implementation rig things
    # such that CONTENT_LENGTH is always first
    # Also map all headers specified in rfc2616 to their canonical case
    ###
    set result {}
    dict set result Content-Length 0
    foreach {key} $data(mimeorder) {
      set ckey $key
      switch [string tolower $key] {
        content-length {
          set ckey Content-Length
        }
        content-encoding {
          set ckey Content-Encoding
        }
        content-language {
          set ckey Content-Language
        }
        content-location {
          set ckey Content-Location
        }
        content-md5 {
          set ckey Content-MD5
        }
        content-range {
          set ckey Content-Range
        }
        content-type {
          set ckey Content-Type
        }
        expires {
          set ckey Expires
        }
        last-modified {
          set ckey Last-Modified
        }
        cookie {
          set ckey COOKIE
        }
        referer -
        referrer {
          # Standard misspelling in the RFC
          set ckey Referer
        }
      }
      dict set result $ckey $data(mime,$key)
    }
    return $result
  }

  method Url_Decode data {
    regsub -all {\+} $data " " data
    regsub -all {([][$\\])} $data {\\\1} data
    regsub -all {%([0-9a-fA-F][0-9a-fA-F])} $data  {[format %c 0x\1]} data
    return [subst $data]
  }

  method Url_PathCheck {urlsuffix} {
    set pathlist ""
    foreach part  [split $urlsuffix /] {
      if {[string length $part] == 0} {
        # It is important *not* to "continue" here and skip
        # an empty component because it could be the last thing,
        # /a/b/c/
        # which indicates a directory.  In this case you want
        # Auth_Check to recurse into the directory in the last step.
      }
      set part [Url_Decode $part]
    	# Disallow Mac and UNIX path separators in components
	    # Windows drive-letters are bad, too
 	    if {[regexp [/\\:] $part]} {
  	    error "URL components cannot include \ or :"
	    }
	    switch -- $part {
	      .  { }
    	  .. {
          set len [llength $pathlist]
          if {[incr len -1] < 0} {
            error "URL out of range"
          }
          set pathlist [lrange $pathlist 0 [incr len -1]]
        }
        default {
          lappend pathlist $part
        }
      }
    }
    return $pathlist
  }


  method wait {mode sock} {
    if {[info coroutine] eq {}} {
      chan event $sock $mode [list set ::httpd::lock_$sock $mode]
      vwait ::httpd::lock_$sock
    } else {
      chan event $sock $mode [info coroutine]
      yield
    }
    chan event $sock $mode {}
  }

}

###
# END: core.tcl
###
###
# START: reply.tcl
###
###
# Define the reply class
###
::tool::define ::httpd::reply {
  superclass ::httpd::mime

  variable transfer_complete 0

  constructor {ServerObj args} {
    my variable chan dispatched_time uuid
    set uuid [namespace tail [self]]
    set dispatched_time [clock milliseconds]
    oo::objdefine [self] forward <server> $ServerObj
    foreach {field value} [::oo::meta::args_to_options {*}$args] {
      my meta set config $field: $value
    }
  }

  ###
  # clean up on exit
  ###
  destructor {
    my close
  }

  method close {} {
    my variable chan
    if {[info exists chan] && $chan ne {}} {
      catch {chan event $chan readable {}}
      catch {chan event $chan writable {}}
      catch {chan flush $chan}
      catch {chan close $chan}
      set chan {}
    }
  }

  method dispatch {newsock datastate} {
    try {
      my http_info replace $datastate
      my request replace  [dict get $datastate http]
      my log Dispatched [dict create \
       REMOTE_ADDR [my http_info get REMOTE_ADDR] \
       REMOTE_HOST [my http_info get REMOTE_HOST] \
       COOKIE [my request get COOKIE] \
       REFERER [my request get REFERER] \
       USER_AGENT [my request get USER_AGENT] \
       REQUEST_URI [my http_info get REQUEST_URI] \
       HTTP_HOST [my http_info getnull HTTP_HOST] \
       SESSION [my http_info getnull SESSION] \
      ]
      my variable chan
      set chan $newsock
      chan event $chan readable {}
      chan configure $chan -translation {auto crlf} -buffering line
      my reset
      # Invoke the URL implementation.
      my content
    } on error {err errdat} {
      my error 500 $err [dict get $errdat -errorinfo]
    } finally {
      my DoOutput
    }
  }

  method html_css {} {
    set result "<link rel=\"stylesheet\" href=\"/style.css\">"
    append result \n {<style media="screen" type="text/css">
body {
	background:  url(images/etoyoc-circuit-tile.gif) repeat;
	font-family: serif;
	color:#000066;
	font-size: 12pt;
}
</style>}
  }

  method html_header {title args} {
    set result {}
    uplevel 1 {
set is_localhost [expr {[lindex [split [my http_info getnull HTTP_HOST] :] 0] eq "localhost"}]
if {$is_localhost} {
  set fossil_root /fossil
} else {
  set fossil_root http://fossil.etoyoc.com/fossil
}
    }
    append result "<HTML><HEAD>"
    if {$title ne {}} {
      append result "<TITLE>$title</TITLE>"
    }
    append result [my html_css]
    append result "</HEAD><BODY>"
    append result \n {<div id="top-menu">}
    if {[dict exists $args banner]} {
      append result "<img src=\"[dict get $args banner]\">"
    } else {
      append result {<img src="/images/etoyoc-banner.jpg">}
    }
    append result {</div>}
    if {[dict exists $args sideimg]} {
      append result "\n<div name=\"sideimg\"><img align=right src=\"[dict get $args sideimg]\" width=25%></div>"
    }
    append result {<div id="content">}
    return $result
  }

  method html_footer {args} {
    set result {</div>}
    append result {</BODY></HTML>}
  }

  dictobj http_info http_info {
    initialize {
      CONTENT_LENGTH 0
    }
    netstring {
      set result {}
      foreach {name value} $%VARNAME% {
        append result $name \x00 $value \x00
      }
      return "[string length $result]:$result,"
    }
  }

  method error {code {msg {}} {errorInfo {}}} {
    my http_info set HTTP_ERROR $code
    my reset
    set qheaders [my http_info dump]
    set HTTP_STATUS "$code [my http_code_string $code]"
    dict with qheaders {}
    my reply replace {}
    my reply set Status $HTTP_STATUS
    my reply set Content-Type {text/html; charset=UTF-8}

    switch $code {
      301 - 302 - 303 - 307 - 308 {
        my reply set Location $msg
        set template [my <server> template redirect]
      }
      404 {
        set template [my <server> template notfound]
      }
      default {
        set template [my <server> template internal_error]
      }
    }
    my puts [subst $template]
  }


  ###
  # REPLACE ME:
  # This method is the "meat" of your application.
  # It writes to the result buffer via the "puts" method
  # and can tweak the headers via "meta put header_reply"
  ###
  method content {} {
    my puts [my html_header {Hello World!}]
    my puts "<H1>HELLO WORLD!</H1>"
    my puts [my html_footer]
  }

  method EncodeStatus {status} {
    return "HTTP/1.0 $status"
  }

  method log {type {info {}}} {
    my variable dispatched_time uuid
    my <server> log $type $uuid $info
  }

  method CoroName {} {
    if {[info coroutine] eq {}} {
      return ::httpd::object::[my http_info get UUID]
    }
  }

  ###
  # Output the result or error to the channel
  # and destroy this object
  ###
  method DoOutput {} {
    my variable reply_body chan
    if {$chan eq {}} return
    catch {
      my wait writable $chan
      chan configure $chan  -translation {binary binary}
      ###
      # Return dynamic content
      ###
      set length [string length $reply_body]
      set result {}
      if {${length} > 0} {
        my reply set Content-Length [string length $reply_body]
        append result [my reply output] \n
        append result $reply_body
      } else {
        append result [my reply output]
      }
      chan puts -nonewline $chan $result
      my log HttpAccess {}
    }
    my destroy
  }

  method FormData {} {
    my variable chan formdata
    # Run this only once
    if {[info exists formdata]} {
      return $formdata
    }
    if {![my request exists CONTENT_LENGTH]} {
      set length 0
    } else {
      set length [my request get CONTENT_LENGTH]
    }
    set formdata {}
    if {[my http_info get REQUEST_METHOD] in {"POST" "PUSH"}} {
      set rawtype [my request get CONTENT_TYPE]
      if {[string toupper [string range $rawtype 0 8]] ne "MULTIPART"} {
        set type $rawtype
      } else {
        set type multipart
      }
      switch $type {
        multipart {
          ###
          # Ok, Multipart MIME is troublesome, farm out the parsing to a dedicated tool
          ###
          set body [my http_info get mimetxt]
          append body \n [my PostData $length]
          set token [::mime::initialize -string $body]
          foreach item [::mime::getheader $token -names] {
            dict set formdata $item [::mime::getheader $token $item]
          }
          foreach item {content encoding params parts size} {
            dict set formdata MIME_[string toupper $item] [::mime::getproperty $token $item]
          }
          dict set formdata MIME_TOKEN $token
        }
        application/x-www-form-urlencoded {
          # These foreach loops are structured this way to ensure there are matched
          # name/value pairs.  Sometimes query data gets garbled.
          set body [my PostData $length]
          set result {}
          foreach pair [split $body "&"] {
            foreach {name value} [split $pair "="] {
              lappend formdata [my Url_Decode $name] [my Url_Decode $value]
            }
          }
        }
      }
    } else {
      foreach pair [split [my http_info getnull QUERY_STRING] "&"] {
        foreach {name value} [split $pair "="] {
          lappend formdata [my Url_Decode $name] [my Url_Decode $value]
        }
      }
    }
    return $formdata
  }

  method PostData {length} {
    my variable postdata
    # Run this only once
    if {[info exists postdata]} {
      return $postdata
    }
    set postdata {}
    if {[my http_info get REQUEST_METHOD] in {"POST" "PUSH"}} {
      my variable chan
      chan configure $chan -translation binary -blocking 0 -buffering full -buffersize 4096
      set postdata [::coroutine::util::read $chan $length]
    }
    return $postdata
  }

  method TransferComplete args {
    my variable chan transfer_complete
    set transfer_complete 1
    my log TransferComplete
    set chan {}
    foreach c $args {
      catch {chan event $c readable {}}
      catch {chan event $c writable {}}
      catch {chan flush $c}
      catch {chan close $c}
    }
    my destroy
  }

  ###
  # Append to the result buffer
  ###
  method puts line {
    my variable reply_body
    append reply_body $line \n
  }

  method RequestFind {field} {
    my variable request
    if {[dict exists $request $field]} {
      return $field
    }
    foreach item [dict keys $request] {
      if {[string tolower $item] eq [string tolower $field]} {
        return $item
      }
    }
    return $field
  }

  dictobj request request {
    field {
      tailcall my RequestFind [lindex $args 0]
    }
    get {
      set field [my RequestFind [lindex $args 0]]
      if {![dict exists $request $field]} {
        return {}
      }
      tailcall dict get $request $field
    }
    getnull {
      set field [my RequestFind [lindex $args 0]]
      if {![dict exists $request $field]} {
        return {}
      }
      tailcall dict get $request $field

    }
    exists {
      set field [my RequestFind [lindex $args 0]]
      tailcall dict exists $request $field
    }
    parse {
      if {[catch {my MimeParse [lindex $args 0]} result]} {
        my error 400 $result
        tailcall my DoOutput
      }
      set request $result
    }
  }

  dictobj reply reply {
    output {
      set result {}
      if {![dict exists $reply Status]} {
        set status {200 OK}
      } else {
        set status [dict get $reply Status]
      }
      set result "[my EncodeStatus $status]\n"
      foreach {f v} $reply {
        if {$f in {Status}} continue
        append result "[string trimright $f :]: $v\n"
      }
      #append result \n
      return $result
    }
  }


  ###
  # Reset the result
  ###
  method reset {} {
    my variable reply_body
    my reply replace    [my HttpHeaders_Default]
    my reply set Server [my <server> cget server_string]
    my reply set Date [my timestamp]
    set reply_body {}
  }

  ###
  # Return true of this class as waited too long to respond
  ###
  method timeOutCheck {} {
    my variable dispatched_time
    if {([clock seconds]-$dispatched_time)>120} {
      ###
      # Something has lasted over 2 minutes. Kill this
      ###
      catch {
        my error 408 {Request Timed out}
        my DoOutput
      }
    }
  }

  ###
  # Return a timestamp
  ###
  method timestamp {} {
    return [clock format [clock seconds] -format {%a, %d %b %Y %T %Z}]
  }
}

###
# END: reply.tcl
###
###
# START: server.tcl
###
###
# An httpd server with a template engine
# and a shim to insert URL domains
###
namespace eval ::httpd::object {}
namespace eval ::httpd::coro {}

::tool::define ::httpd::server {
  superclass ::httpd::mime

  option port  {default: auto}
  option myaddr {default: 127.0.0.1}
  option server_string [list default: [list TclHttpd $::httpd::version]]
  option server_name [list default: [list [info hostname]]]
  option doc_root {default {}}
  option reverse_dns {type boolean default 0}
  option configuration_file {type filename default {}}

  property socket buffersize   32768
  property socket translation  {auto crlf}
  property reply_class ::httpd::reply

  array template
  variable url_patterns {}

  constructor {args} {
    my configure {*}$args
    my start
  }

  destructor {
    my stop
  }

  method connect {sock ip port} {
    ###
    # If an IP address is blocked
    # send a "go to hell" message
    ###
    if {[my Validate_Connection $sock $ip]} {
      catch {close $sock}
      return
    }
    set uuid [my Uuid_Generate]
    set coro [coroutine ::httpd::coro::$uuid {*}[namespace code [list my Connect $uuid $sock $ip]]]
    chan event $sock readable $coro
  }

  method Connect {uuid sock ip} {
    yield [info coroutine]
    chan event $sock readable {}

    chan configure $sock \
      -blocking 0 \
      -translation {auto crlf} \
      -buffering line

    my counter url_hit
    set line {}
    try {
      set readCount [::coroutine::util::gets_safety $sock 4096 line]
      dict set query UUID $uuid
      dict set query REMOTE_ADDR     $ip
      dict set query REMOTE_HOST     [my HostName $ip]
      dict set query REQUEST_METHOD  [lindex $line 0]
      set uriinfo [::uri::split [lindex $line 1]]
      dict set query REQUEST_URI     [lindex $line 1]
      dict set query REQUEST_PATH    [dict get $uriinfo path]
      dict set query REQUEST_VERSION [lindex [split [lindex $line end] /] end]
      dict set query DOCUMENT_ROOT   [my cget doc_root]
      dict set query QUERY_STRING    [dict get $uriinfo query]
      dict set query REQUEST_RAW     $line
      dict set query SERVER_PORT     [my port_listening]
      set mimetxt [my HttpHeaders $sock]
      dict set query mimetxt $mimetxt
      foreach {f v} [my MimeParse $mimetxt] {
        set fld [string toupper [string map {- _} $f]]
        if {$fld in {CONTENT_LENGTH CONTENT_TYPE}} {
          set qfld $fld
        } else {
          set qfld HTTP_$fld
        }
        dict set query $qfld $v
        dict set query http $fld $v
      }
      set reply [my dispatch $query]
    } on error {err errdat} {
      my debug [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      my log BadRequest $uuid [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      catch {chan puts $sock "HTTP/1.0 400 Bad Request (The data is invalid)"}
      catch {chan close $sock}
      return
    }
    if {[llength $reply]==0} {
      my log BadLocation $uuid $query
      chan puts $sock "HTTP/1.0 404 NOT FOUND"
      dict with query {}
      set body [string trim [subst [my template notfound]]]
      chan puts $sock "Content-Length: [string length $body]"
      chan puts $sock {}
      chan puts $sock $body
      chan close $sock
      return
    }
    try {
      if {[dict exists $reply class]} {
        set class [dict get $reply class]
      } else {
        set class [my cget reply_class]
      }
      set pageobj [$class create ::httpd::object::$uuid [self]]
      if {[dict exists $reply mixinmap]} {
        set mixinmap [dict get $reply mixinmap]
      } else {
        set mixinmap {}
      }
      if {[dict exists $reply mixin]} {
        dict set mixinmap reply [dict get $reply mixin]
      }
      foreach item [dict keys $reply MIXIN_*] {
        set slot [string range $reply 6 end]
        dict set mixinmap [string tolower $slot] [dict get $reply $item]
      }
      $pageobj mixinmap {*}$mixinmap
      if {[dict exists $reply organ]} {
        $pageobj graft {*}[dict get $reply organ]
      }
    } on error {err errdat} {
      my debug [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      my log BadRequest $uuid [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      catch {$pageobj destroy}
      catch {chan close $sock}
    }
    try {
      $pageobj dispatch $sock $reply
    } on error {err errdat} {
      my debug [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      my log BadRequest $uuid [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      catch {$pageobj destroy}
      catch {chan close $sock}
    }
  }

  method counter which {
    my variable counters
    incr counters($which)
  }

  ###
  # Clean up any process that has gone out for lunch
  ###
  method CheckTimeout {} {
    foreach obj [info commands ::httpd::object::*] {
      try {
        $obj timeOutCheck
      } on error {} {
        catch {$obj destroy}
      }
    }
  }

  method debug args {}

  ###
  # Route a request to the appropriate handler
  ###
  method dispatch {data} {
    set reply {}
    foreach {f v} $data {
      dict set reply $f $v
    }
    set vhost [lindex [split [dict get $data HTTP_HOST] :] 0]
    set uri   [dict get $data REQUEST_PATH]

    foreach {host pattern info} [my uri patterns] {
      if {![string match $host $vhost]} continue
      if {![string match $pattern /$uri]} continue
      foreach {f v} $info {
        dict set reply $f $v
      }
      if {![dict exists $reply prefix]} {
         dict set reply prefix [my PrefixNormalize $pattern]
      }
      return $reply
    }
    return [my DocDefault $reply]
  }
  method DocDefault {reply} {
    ###
    # Fallback to docroot handling
    ###
    set doc_root [dict get $reply DOCUMENT_ROOT]
    if {$doc_root ne {}} {
      ###
      # Fall back to doc_root handling
      ###
      dict set reply prefix {}
      dict set reply path $doc_root
      dict set reply mixinmap reply httpd::content.file
      return $reply
    }
    return {}
  }

  method HostName ipaddr {
    if {![my cget reverse_dns]} {
      return $ipaddr
    }
    set t [::dns::resolve $ipaddr]
    set result [::dns::name $t]
    ::dns::cleanup $t
    return $result
  }

  method log args {
    # Do nothing for now
  }

  method port_listening {} {
    my variable port_listening
    return $port_listening
  }

  method PrefixNormalize prefix {
    set prefix [string trimright $prefix /]
    set prefix [string trimright $prefix *]
    set prefix [string trimright $prefix /]
    return $prefix
  }

  method source {filename} {
    source $filename
  }

  method start {} {
    # Build a namespace to contain replies
    namespace eval [namespace current]::reply {}

    my variable socklist port_listening
    if {[my cget configuration_file] ne {}} {
      source [my cget configuration_file]
    }
    set port [my cget port]
    if { $port in {auto {}} } {
      package require nettool
      set port [::nettool::allocate_port 8015]
    }
    set port_listening $port
    set myaddr [my cget myaddr]
    my debug [list [self] listening on $port $myaddr]

    if {$myaddr ni {all any * {}}} {
      foreach ip $myaddr {
        lappend socklist [socket -server [namespace code [list my connect]] -myaddr $ip $port]
      }
    } else {
      lappend socklist [socket -server [namespace code [list my connect]] $port]
    }
    ::cron::every [self] 120 [namespace code {my CheckTimeout}]
  }

  method stop {} {
    my variable socklist
    if {[info exists socklist]} {
      foreach sock $socklist {
        catch {close $sock}
      }
    }
    set socklist {}
    ::cron::cancel [self]
  }


  method template page {
    my variable template
    if {[info exists template($page)]} {
      return $template($page)
    }
    set template($page) [my TemplateSearch $page]
    return $template($page)
  }

  method TemplateSearch page {
    set doc_root [my cget doc_root]
    if {$doc_root ne {} && [file exists [file join $doc_root $page.tml]]} {
      return [::fileutil::cat [file join $doc_root $page.tml]]
    }
    if {$doc_root ne {} && [file exists [file join $doc_root $page.html]]} {
      return [::fileutil::cat [file join $doc_root $page.html]]
    }
    switch $page {
      redirect {
return {
[my html header "$HTTP_STATUS"]
The page you are looking for: <b>[my http_info get REQUEST_URI]</b> has moved.
<p>
If your browser does not automatically load the new location, it is
<a href=\"$msg\">$msg</a>
[my html footer]
}
      }
      internal_error {
        return {
[my html header "$HTTP_STATUS"]
Error serving <b>[my http_info get REQUEST_URI]</b>:
<p>
The server encountered an internal server error: <pre>$msg</pre>
<pre><code>
$errorInfo
</code></pre>
[my html footer]
        }
      }
      notfound {
        return {
[my html header "$HTTP_STATUS"]
The page you are looking for: <b>[my http_info get REQUEST_URI]</b> does not exist.
[my html footer]
        }
      }
    }
  }

  method uri::patterns {} {
    my variable url_patterns url_stream
    if {![info exists url_stream]} {
      set url_stream {}
      foreach {host hostpat} $url_patterns {
        foreach {pattern info} $hostpat {
          lappend url_stream $host $pattern $info
        }
      }
    }
    return $url_stream
  }

  method uri::add args {
    my variable url_patterns url_stream
    unset -nocomplain url_stream
    switch [llength $args] {
      2 {
        set vhosts *
        lassign $args patterns info
      }
      3 {
        lassign $args vhosts patterns info
      }
      default {
        error "Usage: add_url ?vhosts? prefix info"
      }
    }
    foreach vhost $vhosts {
      foreach pattern $patterns {
        dict set url_patterns $vhost $pattern $info
      }
    }
  }

  method Uuid_Generate {} {
    return [::uuid::uuid generate]
  }

  ###
  # Return true if this IP address is blocked
  # The socket will be closed immediately after returning
  # This handler is welcome to send a polite error message
  ###
  method Validate_Connection {sock ip} {
    return 0
  }
}

###
# Provide a backward compadible alias
###
::tool::define ::httpd::server::dispatch {
    superclass ::httpd::server
}

###
# END: server.tcl
###
###
# START: dispatch.tcl
###
::tool::define ::httpd::content.redirect {

  method reset {} {
    ###
    # Inject the location into the HTTP headers
    ###
    my variable reply_body
    set reply_body {}
    my reply replace    [my HttpHeaders_Default]
    my reply set Server [my <server> cget server_string]
    set msg [my http_info get LOCATION]
    my reply set Location [my http_info get LOCATION]
    set code  [my http_info getnull REDIRECT_CODE]
    if {$code eq {}} {
      set code 301
    }
    my reply set Status [list $code [my http_code_string $code]]
  }

  method content {} {
    set template [my <server> template redirect]
    set msg [my http_info get LOCATION]
    set HTTP_STATUS [my reply get Status]
    my puts [subst $msg]
  }
}

::tool::define ::httpd::content.cache {

  method dispatch {newsock datastate} {
    my http_info replace $datastate
    my request replace  [dict get $datastate http]
    my variable chan
    set chan $newsock
    chan event $chan readable {}
    try {
      my log Dispatched [dict create \
       REMOTE_ADDR [my http_info get REMOTE_ADDR] \
       REMOTE_HOST [my http_info get REMOTE_HOST] \
       COOKIE [my request get COOKIE] \
       REFERER [my request get REFERER] \
       USER_AGENT [my request get USER_AGENT] \
       REQUEST_URI [my http_info get REQUEST_URI] \
       HTTP_HOST [my http_info getnull HTTP_HOST] \
       SESSION [my http_info getnull SESSION] \
      ]
      my wait writable $chan
      chan configure $chan  -translation {binary binary}
      chan puts -nonewline $chan [my http_info get CACHE_DATA]
    } on error {err info} {
      my <server> debug [dict get $info -errorinfo]
    } finally {
      my TransferComplete $chan
    }
  }
}

###
# END: dispatch.tcl
###
###
# START: file.tcl
###
###
# Class to deliver Static content
# When utilized, this class is fed a local filename
# by the dispatcher
###
::tool::define ::httpd::content.file {

  method FileName {} {
    set uri [string trimleft [my http_info get REQUEST_URI] /]
    set path [my http_info get path]
    set prefix [my http_info get prefix]
    set fname [string range $uri [string length $prefix] end]
    if {$fname in "{} index.html index.md index"} {
      return $path
    }
    if {[file exists [file join $path $fname]]} {
      return [file join $path $fname]
    }
    if {[file exists [file join $path $fname.md]]} {
      return [file join $path $fname.md]
    }
    if {[file exists [file join $path $fname.html]]} {
      return [file join $path $fname.html]
    }
    if {[file exists [file join $path $fname.tml]]} {
      return [file join $path $fname.tml]
    }
    return {}
  }

  method DirectoryListing {local_file} {
    set uri [string trimleft [my http_info get REQUEST_URI] /]
    set path [my http_info get path]
    set prefix [my http_info get prefix]
    set fname [string range $uri [string length $prefix] end]
    my puts [my html header "Listing of /$fname/"]
    my puts "Listing contents of /$fname/"
    my puts "<TABLE>"
    if {$prefix ni {/ {}}} {
      set updir [file dirname $prefix]
      if {$updir ne {}} {
        my puts "<TR><TD><a href=\"/$updir\">..</a></TD><TD></TD></TR>"
      }
    }
    foreach file [glob -nocomplain [file join $local_file *]] {
      if {[file isdirectory $file]} {
        my puts "<TR><TD><a href=\"[file join / $uri [file tail $file]]\">[file tail $file]/</a></TD><TD></TD></TR>"
      } else {
        my puts "<TR><TD><a href=\"[file join / $uri [file tail $file]]\">[file tail $file]</a></TD><TD>[file size $file]</TD></TR>"
      }
    }
    my puts "</TABLE>"
    my puts [my html footer]
  }

  method content {} {
    my variable reply_file
    set local_file [my FileName]
    if {$local_file eq {} || ![file exist $local_file]} {
      my log httpNotFound [my http_info get REQUEST_URI]
      my error 404 {File Not Found}
      tailcall my DoOutput
    }
    if {[file isdirectory $local_file] || [file tail $local_file] in {index index.html index.tml index.md}} {
      ###
      # Produce an index page
      ###
      set idxfound 0
      foreach name {
        index.html
        index.tml
        index.md
      } {
        if {[file exists [file join $local_file $name]]} {
          set idxfound 1
          set local_file [file join $local_file $name]
          break
        }
      }
      if {!$idxfound} {
        tailcall my DirectoryListing $local_file
      }
    }
    switch [file extension $local_file] {
      .md {
        package require Markdown
        my reply set Content-Type {text/html; charset=UTF-8}
        set mdtxt  [::fileutil::cat $local_file]
        my puts [::Markdown::convert $mdtxt]
      }
      .tml {
        my reply set Content-Type {text/html; charset=UTF-8}
        set tmltxt  [::fileutil::cat $local_file]
        set headers [my http_info dump]
        dict with headers {}
        my puts [subst $tmltxt]
      }
      default {
        ###
        # Assume we are returning a binary file
        ###
        my reply set Content-Type [::fileutil::magic::filetype $local_file]
        set reply_file $local_file
      }
    }
  }

  method dispatch {newsock datastate} {
    my variable reply_body reply_file reply_chan chan
    try {
      my http_info replace $datastate
      my request replace  [dict get $datastate http]
      my log Dispatched [dict create \
       REMOTE_ADDR [my http_info get REMOTE_ADDR] \
       REMOTE_HOST [my http_info get REMOTE_HOST] \
       COOKIE [my request get COOKIE] \
       REFERER [my request get REFERER] \
       USER_AGENT [my request get USER_AGENT] \
       REQUEST_URI [my http_info get REQUEST_URI] \
       HTTP_HOST [my http_info getnull HTTP_HOST] \
       SESSION [my http_info getnull SESSION] \
      ]
      set chan $newsock
      chan event $chan readable {}
      chan configure $chan -translation {auto crlf} -buffering line

      my reset
      # Invoke the URL implementation.
      my content
    } on error {err errdat} {
      my error 500 $err [dict get $errdat -errorinfo]
      tailcall my DoOutput
    }
    if {$chan eq {}} return
    my wait writable $chan
    if {![info exists reply_file]} {
      tailcall my DoOutput
    }
    try {
      chan configure $chan  -translation {binary binary}
      my log HttpAccess {}
      ###
      # Return a stream of data from a file
      ###
      set size [file size $reply_file]
      my reply set Content-Length $size
      append result [my reply output] \n
      chan puts -nonewline $chan $result
      set reply_chan [open $reply_file r]
      my log SendReply [list length $size]
      chan configure $reply_chan  -translation {binary binary}
      ###
      # Send any POST/PUT/etc content
      # Note, we are terminating the coroutine at this point
      # and using the file event to wake the object back up
      #
      # We *could*:
      # chan copy $sock $chan -command [info coroutine]
      # yield
      #
      # But in the field this pegs the CPU for long transfers and locks
      # up the process
      ###
      chan copy $reply_chan $chan -command [namespace code [list my TransferComplete $reply_chan $chan]]
    } on error {err errdat} {
      my TransferComplete $reply_chan $chan
    }
  }
}

###
# END: file.tcl
###
###
# START: proxy.tcl
###
::tool::define ::httpd::content.exec {
  variable exename [list tcl [info nameofexecutable] .tcl [info nameofexecutable]]

  method CgiExec {execname script arglist} {
    if { $::tcl_platform(platform) eq "windows"} {
      if {[file extension $script] eq ".exe"} {
        return [open "|[list $script] $arglist" r+]
      } else {
        if {$execname eq {}} {
          set execname [my Cgi_Executable $script]
        }
        return [open "|[list $execname $script] $arglist" r+]
      }
    } else {
      if {$execname eq {}} {
        return [open "|[list $script] $arglist 2>@1" r+]
      } else {
        return [open "|[list $execname $script] $arglist 2>@1" r+]
      }
    }
    error "CGI Not supported"
  }

  method Cgi_Executable {script} {
    if {[string tolower [file extension $script]] eq ".exe"} {
      return $script
    }
    my variable exename
    set ext [file extension $script]
    if {$ext eq {}} {
      set which [file tail $script]
    } else {
      if {[dict exists exename $ext]} {
        return [dict get $exename $ext]
      }
      switch $ext {
        .pl {
          set which perl
        }
        .py {
          set which python
        }
        .php {
          set which php
        }
        .fossil - .fos {
          set which fossil
        }
        default {
          set which tcl
        }
      }
      if {[dict exists exename $which]} {
        set result [dict get $exename $which]
        dict set exename $ext $result
        return $result
      }
    }
    if {[dict exists exename $which]} {
      return [dict get $exename $which]
    }
    if {$which eq "tcl"} {
      if {[my cget tcl_exe] ne {}} {
        dict set exename $which [my cget tcl_exe]
      } else {
        dict set exename $which [info nameofexecutable]
      }
    } else {
      if {[my cget ${which}_exe] ne {}} {
        dict set exename $which [my cget ${which}_exe]
      } elseif {"$::tcl_platform(platform)" == "windows"} {
        dict set exename $which $which.exe
      } else {
        dict set exename $which $which
      }
    }
    set result [dict get $exename $which]
    if {$ext ne {}} {
      dict set exename $ext $result
    }
    return $result
  }
}

###
# Return data from an proxy process
###
::tool::define ::httpd::content.proxy {
  superclass ::httpd::content.exec

  method proxy_channel {} {
    ###
    # This method returns a channel to the
    # proxied socket/stdout/etc
    ###
    error unimplemented
  }

  method proxy_path {} {
    set uri [string trimleft [my http_info get REQUEST_URI] /]
    set prefix [my http_info get prefix]
    return /[string range $uri [string length $prefix] end]
  }

  method ProxyRequest {chana chanb} {
    chan event $chanb writable {}
    my log ProxyRequest {}
    chan puts $chanb "[my http_info get REQUEST_METHOD] [my proxy_path]"
    chan puts $chanb [my http_info get mimetxt]
    set length [my http_info get CONTENT_LENGTH]
    if {$length} {
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      ###
      # Send any POST/PUT/etc content
      ###
      chan copy $chana $chanb -size $length -command [info coroutine]
    } else {
      chan flush $chanb
      chan event $chanb readable [info coroutine]
    }
    yield
  }

  method ProxyReply {chana chanb args} {
    my log ProxyReply [list args $args]
    chan event $chana readable {}
    set readCount [::coroutine::util::gets_safety $chana 4096 reply_status]
    set replyhead [my HttpHeaders $chana]
    set replydat  [my MimeParse $replyhead]
    if {![dict exists $replydat Content-Length]} {
      set length 0
    } else {
      set length [dict get $replydat Content-Length]
    }
    ###
    # Read the first incoming line as the HTTP reply status
    # Return the rest of the headers verbatim
    ###
    set replybuffer "$reply_status\n"
    append replybuffer $replyhead
    chan configure $chanb -translation {auto crlf} -blocking 0 -buffering full -buffersize 4096
    chan puts $chanb $replybuffer
    my log SendReply [list length $length]
    if {$length} {
      ###
      # Output the body
      ###
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      chan copy $chana $chanb -size $length -command [namespace code [list my TransferComplete $chana $chanb]]
    } else {
      my TransferComplete $chana $chanb
    }
  }

  method dispatch {newsock datastate} {
    try {
      my http_info replace $datastate
      my request replace  [dict get $datastate http]
      my log Dispatched [dict create \
       REMOTE_ADDR [my http_info get REMOTE_ADDR] \
       REMOTE_HOST [my http_info get REMOTE_HOST] \
       COOKIE [my request get COOKIE] \
       REFERER [my request get REFERER] \
       USER_AGENT [my request get USER_AGENT] \
       REQUEST_URI [my http_info get REQUEST_URI] \
       HTTP_HOST [my http_info getnull HTTP_HOST] \
       SESSION [my http_info getnull SESSION] \
      ]
      my variable sock chan
      set chan $newsock
      chan configure $chan -translation {auto crlf} -buffering line
      # Initialize the reply
      my reset
      # Invoke the URL implementation.
    } on error {err errdat} {
      my error 500 $err [dict get $errdat -errorinfo]
      tailcall my DoOutput
    }
    if {[catch {my proxy_channel} sock errdat]} {
      my error 504 {Service Temporarily Unavailable} [dict get $errdat -errorinfo]
      tailcall my DoOutput
    }
    if {$sock eq {}} {
      my error 404 {Not Found}
      tailcall my DoOutput
    }
    my log HttpAccess {}
    chan event $sock writable [info coroutine]
    yield
    my ProxyRequest $chan $sock
    my ProxyReply   $sock $chan
  }
}

###
# END: proxy.tcl
###
###
# START: cgi.tcl
###
::tool::define ::httpd::content.cgi {
  superclass ::httpd::content.proxy

  method FileName {} {
    set uri [string trimleft [my http_info get REQUEST_URI] /]
    set path [my http_info get path]
    set prefix [my http_info get prefix]

    set fname [string range $uri [string length $prefix] end]
    if {[file exists [file join $path $fname]]} {
      return [file join $path $fname]
    }
    if {[file exists [file join $path $fname.fossil]]} {
      return [file join $path $fname.fossil]
    }
    if {[file exists [file join $path $fname.fos]]} {
      return [file join $path $fname.fos]
    }
    if {[file extension $fname] in {.exe .cgi .tcl .pl .py .php}} {
      return $fname
    }
    return {}
  }

  method proxy_channel {} {
    ###
    # When delivering static content, allow web caches to save
    ###
    set local_file [my FileName]
    if {$local_file eq {} || ![file exist $local_file]} {
      my log httpNotFound [my http_info get REQUEST_URI]
      my error 404 {Not Found}
      tailcall my DoOutput
    }
    if {[file isdirectory $local_file]} {
      ###
      # Produce an index page... or error
      ###
      tailcall my DirectoryListing $local_file
    }

    set verbatim {
      CONTENT_LENGTH CONTENT_TYPE QUERY_STRING REMOTE_USER AUTH_TYPE
      REQUEST_METHOD REMOTE_ADDR REMOTE_HOST REQUEST_URI REQUEST_PATH
      REQUEST_VERSION  DOCUMENT_ROOT QUERY_STRING REQUEST_RAW
      GATEWAY_INTERFACE SERVER_PORT SERVER_HTTPS_PORT
      SERVER_NAME  SERVER_SOFTWARE SERVER_PROTOCOL
    }
    foreach item $verbatim {
      set ::env($item) {}
    }
    foreach item [array names ::env HTTP_*] {
      set ::env($item) {}
    }
    set ::env(SCRIPT_NAME) [my http_info get REQUEST_PATH]
    set ::env(SERVER_PROTOCOL) HTTP/1.0
    set ::env(HOME) $::env(DOCUMENT_ROOT)
    foreach {f v} [my http_info dump] {
      if {$f in $verbatim} {
        set ::env($f) $v
      }
    }
  	set arglist $::env(QUERY_STRING)
    set pwd [pwd]
    cd [file dirname $local_file]
    foreach {f v} [my request dump] {
      if {$f in $verbatim} {
        set ::env($f) $v
      } else {
        set ::env(HTTP_$f) $v
      }
    }
    set script_file $local_file
    if {[file extension $local_file] in {.fossil .fos}} {
      if {![file exists $local_file.cgi]} {
        set fout [open $local_file.cgi w]
        chan puts $fout "#!/usr/bin/fossil"
        chan puts $fout "repository: $local_file"
        close $fout
      }
      set script_file $local_file.cgi
      set EXE [my Cgi_Executable fossil]
    } else {
      set EXE [my Cgi_Executable $local_file]
    }
    set ::env(PATH_TRANSLATED) $script_file
    set pipe [my CgiExec $EXE $script_file $arglist]
    cd $pwd
    return $pipe
  }

  method ProxyRequest {chana chanb} {
    chan event $chanb writable {}
    my log ProxyRequest {}
    set length [my http_info get CONTENT_LENGTH]
    if {$length} {
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      ###
      # Send any POST/PUT/etc content
      ###
      chan copy $chana $chanb -size $length -command [info coroutine]
    } else {
      chan flush $chanb
      chan event $chanb readable [info coroutine]
    }
    yield

  }


  method ProxyReply {chana chanb args} {
    my log ProxyReply [list args $args]
    chan event $chana readable {}
    set replyhead [my HttpHeaders $chana]
    set replydat  [my MimeParse $replyhead]
    if {![dict exists $replydat Content-Length]} {
      set length 0
    } else {
      set length [dict get $replydat Content-Length]
    }
    ###
    # Convert the Status: header from the CGI process to
    # a standard service reply line from a web server, but
    # otherwise spit out the rest of the headers verbatim
    ###
    set replybuffer "HTTP/1.0 [dict get $replydat Status]\n"
    append replybuffer $replyhead
    chan configure $chanb -translation {auto crlf} -blocking 0 -buffering full -buffersize 4096
    chan puts $chanb $replybuffer
    my log SendReply [list length $length]
    if {$length} {
      ###
      # Output the body
      ###
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      chan copy $chana $chanb -size $length -command [namespace code [list my TransferComplete $chana $chanb]]
    } else {
      my TransferComplete $chana $chanb
    }
  }

  ###
  # For most CGI applications a directory list is vorboten
  ###
  method DirectoryListing {local_file} {
    my error 403 {Not Allowed}
    tailcall my DoOutput
  }
}

###
# END: cgi.tcl
###
###
# START: scgi.tcl
###
###
# Return data from an SCGI process
###
::tool::define ::httpd::content.scgi {
  superclass ::httpd::content.proxy

  method scgi_info {} {
    ###
    # This method should check if a process is launched
    # or launch it if needed, and return a list of
    # HOST PORT SCRIPT_NAME
    ###
    # return {localhost 8016 /some/path}
    error unimplemented
  }

  method proxy_channel {} {
    set sockinfo [my scgi_info]
    if {$sockinfo eq {}} {
      my error 404 {Not Found}
      tailcall my DoOutput
    }
    lassign $sockinfo scgihost scgiport scgiscript
    my http_info set SCRIPT_NAME $scgiscript
    if {![string is integer $scgiport]} {
      my error 404 {Not Found}
      tailcall my DoOutput
    }
    return [::socket $scgihost $scgiport]
  }

  method ProxyRequest {chana chanb} {
    chan event $chanb writable {}
    my log ProxyRequest {}
    chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
    chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
    set info [dict create CONTENT_LENGTH 0 SCGI 1.0 SCRIPT_NAME [my http_info get SCRIPT_NAME]]
    foreach {f v} [my http_info dump] {
      dict set info $f $v
    }
    set length [dict get $info CONTENT_LENGTH]
    set block {}
    foreach {f v} $info {
      append block [string toupper $f] \x00 $v \x00
    }
    chan puts -nonewline $chanb "[string length $block]:$block,"
    # Light off another coroutine
    #set cmd [list coroutine [my CoroName] {*}[namespace code [list my ProxyReply $chanb $chana]]]
    if {$length} {
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      ###
      # Send any POST/PUT/etc content
      ###
      chan copy $chana $chanb -size $length -command [info coroutine]
    } else {
      chan flush $chanb
      chan event $chanb readable [info coroutine]
    }
    yield
  }

  method ProxyReply {chana chanb args} {
    my log ProxyReply [list args $args]
    chan event $chana readable {}
    set replyhead [my HttpHeaders $chana]
    set replydat  [my MimeParse $replyhead]
    if {![dict exists $replydat Content-Length]} {
      set length 0
    } else {
      set length [dict get $replydat Content-Length]
    }
    ###
    # Convert the Status: header from the CGI process to
    # a standard service reply line from a web server, but
    # otherwise spit out the rest of the headers verbatim
    ###
    set replybuffer "HTTP/1.0 [dict get $replydat Status]\n"
    append replybuffer $replyhead
    chan configure $chanb -translation {auto crlf} -blocking 0 -buffering full -buffersize 4096
    chan puts $chanb $replybuffer
    my log SendReply [list length $length]
    if {$length} {
      ###
      # Output the body
      ###
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      chan copy $chana $chanb -size $length -command [namespace code [list my TransferComplete $chana $chanb]]
    } else {
      my TransferComplete $chan $chanb
    }
  }
}

tool::define ::httpd::reply.scgi {
  superclass ::httpd::reply

  method EncodeStatus {status} {
    return "Status: $status"
  }
}

###
# Act as an  SCGI Server
###
tool::define ::httpd::server.scgi {
  superclass ::httpd::server

  property socket buffersize   32768
  property socket blocking     0
  property socket translation  {binary binary}

  property reply_class ::httpd::reply.scgi

  method Connect {uuid sock ip} {
    yield [info coroutine]
    chan event $sock readable {}
    chan configure $sock \
        -blocking 1 \
        -translation {binary binary} \
        -buffersize 4096 \
        -buffering none
    my counter url_hit
    try {
      # Read the SCGI request on byte at a time until we reach a ":"
      dict set query REQUEST_URI /
      dict set query REMOTE_ADDR     $ip
      set size {}
      while 1 {
        set char [::coroutine::util::read $sock 1]
        if {[chan eof $sock]} {
          catch {close $sock}
          return
        }
        if {$char eq ":"} break
        append size $char
      }
      # With length in hand, read the netstring encoded headers
      set inbuffer [::coroutine::util::read $sock [expr {$size+1}]]
      chan configure $sock -blocking 0 -buffersize 4096 -buffering full
      foreach {f v} [lrange [split [string range $inbuffer 0 end-1] \0] 0 end-1] {
        dict set query $f $v
        if {$f in {CONTENT_LENGTH CONTENT_TYPE}} {
          dict set query http $f $v
        } elseif {[string range $f 0 4] eq "HTTP_"} {
          dict set query http [string range $f 5 end] $v
        }
      }
      if {![dict exists $query REQUEST_PATH]} {
        set uri [dict get $query REQUEST_URI]
        set uriinfo [::uri::split $uri]
        dict set query REQUEST_PATH    [dict get $uriinfo path]
      }
      set reply [my dispatch $query]
      dict with query {}
      if {[llength $reply]} {
        if {[dict exists $reply class]} {
          set class [dict get $reply class]
        } else {
          set class [my cget reply_class]
        }
        set pageobj [$class create [namespace current]::reply$uuid [self]]
        if {[dict exists $reply mixin]} {
          oo::objdefine $pageobj mixin [dict get $reply mixin]
        }
        $pageobj dispatch $sock $reply
        my log HttpAccess $REQUEST_URI
      } else {
        try {
          my log HttpMissing $REQUEST_URI
          chan puts $sock "Status: 404 NOT FOUND"
          dict with query {}
          set body [subst [my template notfound]]
          chan puts $sock "Content-Length: [string length $body]"
          chan puts $sock {}
          chan puts $sock $body
        } on error {err errdat} {
          my <server> debug "FAILED ON 404: $err [dict get $errdat -errorinfo]"
        } finally {
          catch {chan event readable $sock {}}
          catch {chan event writeable $sock {}}
          catch {chan close $sock}
        }
      }
    } on error {err errdat} {
      try {
        my <server> debug [dict get $errdat -errorinfo]
        chan puts $sock "Status: 500 INTERNAL ERROR - scgi 298"
        dict with query {}
        set body [subst [my template internal_error]]
        chan puts $sock "Content-Length: [string length $body]"
        chan puts $sock {}
        chan puts $sock $body
        my log HttpError [list error [my http_info get REMOTE_ADDR] errorinfo [dict get $errdat -errorinfo]]
      } on error {err errdat} {
        my log HttpFatal [list error [my http_info get REMOTE_ADDR] errorinfo [dict get $errdat -errorinfo]]
        my <server> debug "Failed on 500: [dict get $errdat -errorinfo]""
      } finally {
        catch {chan event readable $sock {}}
        catch {chan event writeable $sock {}}
        catch {chan close $sock}
      }
    }
  }
}

###
# END: scgi.tcl
###
###
# START: websocket.tcl
###
###
# Upgrade a connection to a websocket
###
::tool::define ::httpd::content.websocket {

}

###
# END: websocket.tcl
###

namespace eval ::httpd {
    namespace export *
}

