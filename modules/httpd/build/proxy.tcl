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
