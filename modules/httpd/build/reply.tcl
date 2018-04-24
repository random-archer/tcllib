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

  method Log_Dispatched {} {
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
  }

  method dispatch {newsock datastate} {
    my http_info replace $datastate
    my request replace  [dict getnull $datastate http]
    my Log_Dispatched
    my variable chan
    set chan $newsock
    try {
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
    set result {</div><div id="footer">}
    append result {</div></BODY></HTML>}
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
