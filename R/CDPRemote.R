#' @include utils.R
#' @include http_methods.R
#' @include CDPSession.R
#' @include hold.R
#' @importFrom assertthat assert_that is.scalar is.number
NULL

#' Declare a remote application implementing the Chrome Debugging Protocol
#'
#' This class aims to declare an application implementing the Chrome Debugging
#' Protocol. It possesses methods to manage connections.
#'
#' @section Usage:
#' ```
#' remote <- CDPRemote$new(host = "localhost", debug_port = 9222, secure = FALSE,
#'                         local = FALSE, retry_delay = 0.2, max_attempts = 15L)
#'
#' remote$connect(callback = NULL)
#' remote$listConnections()
#' remote$closeConnections(callback = NULL)
#' remote$version()
#' remote$user_agent
#' ```
#'
#' @section Arguments:
#' * `remote`: an object representing a remote application implementing the
#'     Chrome Debugging Protocol.
#' * `host`: Character scalar, the host name of the application.
#' * `debug_port`: Integer scalar, the remote debugging port.
#' * `secure`: Logical scalar, indicating whether the https/wss protocols
#'     shall be used for connecting to the remote application.
#' * `local`: Logical scalar, indicating whether the local version of the
#'     protocol (embedded in `crrri`) must be used or the protocol must be
#'     fetched _remotely_.
#' * `retry_delay`: Number, delay in seconds between two successive tries to
#'     connect to the remote application.
#' * `max_attempts`: Integer scalar, number of tries to connect to headless
#'     Chromium/Chrome.
#' * `callback`: Function with one argument.
#'
#' @section Details:
#' `$new()` declares a new remote application.
#'
#' `$connect(callback = NULL)` connects the R session to the remote application.
#' The returned value depends on the value of the `callback` argument. When
#' `callback` is a function, the returned value is a connection object. When
#' `callback` is `NULL` the returned value is a promise which fulfills once R
#' is connected to the remote application. Once fulfilled, the value of this
#' promise is the connection object.
#'
#' `$listConnections()` returns a list of the connection objects succesfully
#' created using the `$connect()` method.
#'
#' `$closeConnections(callback = NULL)` closes all the connections created using
#' the `$connect()` method. If `callback` is `NULL`, it returns a promise which
#' fulfills when all the connections are closed: once fulfilled, its value is the
#' remote object.
#' If `callback` is not `NULL`, it returns the remote object. In this case,
#' `callback` is called when all the connections are closed and the remote object is
#' passed to this function as the argument.
#'
#' `$version()` executes the DevTools `Version` method. It returns a list of
#' informations available at `http://<host>:<debug_port>/json/version`.
#'
#' `$user_agent` returns a character scalar with the User Agent of the
#' remote application.
#'
#' `$listTargets()` returns a list with information about targets (or tabs).
#'
#' @name CDPRemote
#' @examples
#' \dontrun{
#' # Assuming that an application is already running at http://localhost:9222
#' # For instance, you can execute:
#' # chrome <- Chrome$new()
#'
#' remote <- CDPRemote$new()
#'
#' remote$connect() %...>% (function(client) {
#'   Page <- client$Page
#'   Runtime <- client$Runtime
#'
#'   Page$enable() %...>% {
#'     Page$navigate(url = 'http://r-project.org')
#'   } %...>% {
#'     Page$loadEventFired()
#'   } %...>% {
#'     Runtime$evaluate(
#'       expression = 'document.documentElement.outerHTML'
#'     )
#'   } %...>% (function(result) {
#'     cat(result$result$value, "\n")
#'   }) %...!% {
#'     cat("Error:", .$message, "\n")
#'   } %>%
#'   promises::finally(~ client$disconnect())
#' }) %...!% {
#'   cat("Error:", .$message, "\n")
#' }
#' }
#'
NULL

#' @export
CDPRemote <- R6::R6Class(
  "CDPRemote",
  public = list(
    initialize = function(
      host = "localhost", debug_port = 9222, secure = FALSE, local = FALSE,
      retry_delay = 0.2, max_attempts = 15L
    ) {
      assert_that(is_scalar_character(host))
      assert_that(is.number(debug_port))
      assert_that(is.scalar(secure), is.logical(secure))
      assert_that(is.scalar(local), is.logical(local))
      assert_that(is.number(retry_delay))
      assert_that(is_scalar_integerish(max_attempts))

      private$.port <- debug_port
      private$.secure <- secure
      private$.local_protocol <- isTRUE(local)
      private$.retry_delay <- retry_delay
      private$.max_attempts <- max_attempts
      remote_reachable <- is_remote_reachable(host, debug_port, secure, retry_delay, max_attempts)
      if(!remote_reachable && host == "localhost") {
        host <- "127.0.0.1"
        remote_reachable <- is_remote_reachable(host, debug_port, secure, retry_delay, max_attempts)
      }
      if(!remote_reachable) {
        warning("Cannot access to remote host...")
        private$.reachable <- FALSE
      }
      private$.host <- host
      self$version() # run once to store version
    },
    connect = function(callback = NULL, .target_id = "default") {
      async <- is.null(callback)

      if(!is.null(callback)) {
        callback <- rlang::as_function(callback)
        assertthat::assert_that(
          length(rlang::fn_fmls(callback)) > 0,
          msg = "The callback function must have one argument."
        )
      }
      private$.check_remote()
      if(!private$.reachable) {
        return(stop_or_reject(
          "Cannot access to remote host.",
          async = async
        ))
      }

      if(identical(.target_id, "default")) {
        # test if there is an available target
        if(length(self$listTargets()) == 0L) {
          return(self$connectToNewTab(callback = callback))
        }
        ws_url <- chr_get_ws_addr(private$.host, private$.port, private$.secure)
      } else {
        targets <- self$listTargets()
        # extracts targets identifiers:
        ids <- purrr::map_chr(self$listTargets(), "id")
        # find the position of .target_id in this character vector
        pos <- purrr::detect_index(ids, ~ identical(.x, .target_id))
        # if .target_id is not in the list, its position is 0
        if(pos == 0) {
          return(stop_or_reject(
            "unable to connect: wrong target ID.",
            async = async
          ))
        }
        # retrieve the websocket address associated with target_id:
        ws_url <- purrr::pluck(targets, pos, "webSocketDebuggerUrl")
      }

      con <- CDPSession(
        host = private$.host,
        port = private$.port,
        secure = private$.secure,
        ws_url = ws_url,
        local = private$.local_protocol,
        callback = callback
      )
      if(promises::is.promise(con)) {
        promises::then(
          con,
          onFulfilled = function(value) {
            private$.clients <- c(private$.clients, list(value))
          },
          onRejected = function(err) {
            warning(err$message, call. = FALSE, immediate. = TRUE)
          }
        )
      } else {
        private$.clients <- c(private$.clients, list(con))
      }
      con
    },
    listConnections = function() {
      private$.clients
    },
    closeConnections = function(callback = NULL) {
      if(!is.null(callback)) {
        callback <- rlang::as_function(callback)
      }
      async <- is.null(callback)

      if(async) {
        # CDPSession disconnect() method returns a promise
        disconnected <- promises::promise_all(
          .list = purrr::map(private$.clients, function(client) {
            client$disconnect()
          })
        )
        # when connections are closed, remove them from the list of clients
        # and return the remote object (i.e. self)
        cleaned <- promises::then(
          disconnected,
          onFulfilled = function(value) {
            private$.clients <- list()
            invisible(self)
          }
        )
        return(cleaned)
      } else {
        token <- new.env()
        token$done <- FALSE
        client_callback <- function(client) {
          if(private$.are_clients_closed() && !token$done) {
            private$.clients <- list()
            token$done <- TRUE
            callback(self)
          }
        }
        if(identical(length(private$.clients), 0L)) {
          on.exit(callback(self), add = TRUE)
        }
        purrr::walk(private$.clients, ~ .x$disconnect(callback = client_callback))
        return(invisible(self))
      }
    },
    version = function() {
      private$.check_remote()
      if(private$.reachable) {
        # if remote is opened, update the private field .version
        private$.version <- fetch_version(private$.host, private$.port, private$.secure)
      }
      private$.version
    },
    listTargets = function() {
      private$.check_remote()
      if(private$.reachable) {
        list_targets(private$.host, private$.port, private$.secure)
      } else {
        warning("cannot access to remote host.")
      }
    },
    connectToNewTab = function(url = NULL, callback = NULL) {
      target <- new_tab(private$.host, private$.port, private$.secure, url)
      if(is.null(target$id)) {
        return(
          stop_or_reject(
            "Unable to create a new tab.",
            async = is.null(callback)
          )
        )
      }
      self$connect(callback = callback, .target_id = target$id)
    },
    print = function() {
      version <- self$version()
      cat(sep = "",
          "<", version$Browser, ">\n",
          '  url: ', build_http_url(private$.host, private$.port, private$.secure), "\n",
          '  user-agent:\n',
          '    "', version$`User-Agent`, '"\n'
      )
    }
  ),
  active = list(
    user_agent = function() {
      self$version()$`User-Agent`
    }
  ),
  private = list(
    .host = NULL,
    .port = NULL,
    .secure = FALSE,
    .local_protocol = FALSE,
    .retry_delay = 0.2,
    .max_attempts = 15L,
    .reachable = TRUE,
    .version = list(),
    .clients = list(),
    .check_remote = function() {
      if(private$.reachable) {
        private$.reachable <- is_remote_reachable(
          private$.host,
          private$.port,
          private$.secure,
          private$.retry_delay,
          private$.max_attempts
        )
      }
    },
    .are_clients_closed = function() {
      all(purrr::map_lgl(private$.clients, ~ .x$readyState() == 3L))
    },
    finalize = function() {
      # since we are in finalize, we can use hold() safely
      hold(
        self$closeConnections(),
        timeout = 10,
        msg = "The WebSocket connections have not been properly closed."
      )
    }
  )
)
