map     = require("lodash/map")
pick    = require("lodash/pick")
once    = require("lodash/once")
Promise = require("bluebird")

HOST = "CHANGE_ME_HOST"
PATH = "CHANGE_ME_PATH"

# lastFocusedWindowId = null
# lastFocusedChange   = new Date

firstOrNull = (cookies) ->
  ## normalize into null when empty array
  cookies[0] ? null

connect = (host, path, io) ->
  io ?= global.io

  ## bail if io isnt defined
  return if not io

  listenToCookieChanges = once ->
    chrome.cookies.onChanged.addListener (info) ->
      if info.cause isnt "overwrite"
        client.emit("automation:push:request", "change:cookie", info)

  # listenToFocusChanges = once ->
  #   chrome.windows.onFocusChanged.addListener (winId) ->
  #     console.log "focus change detected, resetting time", winId
  #     lastFocusedWindowId = winId
  #     lastFocusedChange = new Date

  fail = (id, err) ->
    client.emit("automation:response", id, {
      __error: err.message
      __stack: err.stack
      __name:  err.name
    })

  invoke = (method, id, args...) ->
    respond = (data) ->
      client.emit("automation:response", id, {response: data})

    Promise.try ->
      automation[method].apply(automation, args.concat(respond))
    .catch (err) ->
      fail(id, err)

  ## cannot use required socket here due
  ## to bug in socket io client with browserify
  client = io.connect(host, {path: path})

  client.on "automation:request", (id, msg, data) ->
    switch msg
      when "get:cookies"
        invoke("getCookies", id, data)
      when "get:cookie"
        invoke("getCookie", id, data)
      when "set:cookie"
        invoke("setCookie", id, data)
      when "clear:cookies"
        invoke("clearCookies", id, data)
      when "clear:cookie"
        invoke("clearCookie", id, data)
      when "is:automation:connected"
        invoke("verify", id, data)
      when "focus:browser"
        invoke("focusBrowser", id)
      when "move:browser"
        invoke("moveBrowser", id, data)
      else
        fail(id, {message: "No handler registered for: '#{msg}'"})

  client.on "connect", ->
    listenToCookieChanges()
    # listenToFocusChanges()

    client.emit("automation:connected")

  return client

## initially connect
connect(HOST, PATH, global.io)

automation = {
  connect: connect

  getUrl: (cookie = {}) ->
    prefix = if cookie.secure then "https://" else "http://"
    prefix + cookie.domain + cookie.path

  clear: (filter = {}) ->
    clear = (cookie) =>
      new Promise (resolve, reject) =>
        url = @getUrl(cookie)
        chrome.cookies.remove {url: url, name: cookie.name}, (details) ->
          if details
            resolve(cookie)
          else
            reject(chrome.runtime.lastError)

    @getAll(filter)
    .map(clear)

  getAll: (filter = {}) ->
    get = ->
      new Promise (resolve) ->
        chrome.cookies.getAll(filter, resolve)

    get()

  getCookies: (filter, fn) ->
    @getAll(filter)
    .then(fn)

  getCookie: (filter, fn) ->
    @getAll(filter)
    .then(firstOrNull)
    .then(fn)

  setCookie: (props = {}, fn) ->
    set = =>
      new Promise (resolve, reject) =>
        props.url = @getUrl(props)
        chrome.cookies.set props, (details) ->
          if details
            resolve(details)
          else
            reject(chrome.runtime.lastError)

    set()
    .then(fn)

  clearCookie: (filter, fn) ->
    @clear(filter)
    .then(firstOrNull)
    .then(fn)

  clearCookies: (filter, fn) ->
    @clear(filter)
    .then(fn)

  focusBrowser: (fn) ->
    ## lets just make this simple and whatever is the current
    ## window bring that into focus
    ##
    ## TODO: if we REALLY want to be nice its possible we can
    ## figure out the exact window that's running Cypress but
    ## that's too much work with too little value at the moment
    ## if our last focus came less than 1 second
    ## ago then don't do anything
    # console.log (new Date - lastFocusedChange)
    # if (new Date - lastFocusedChange) < 1000
    #   return fn()

    ## query for tabs which match
    ## our expected host
    ## ie: http://localhost:2020/*
    url  = HOST + "/*"
    code = "document.visibilityState"

    query = ->
      new Promise (resolve) ->
        chrome.tabs.query({url: url, windowType: "normal"}, resolve)

    makeActive = (tab) ->
      return if not tab

      new Promise (resolve) ->
        r = -> resolve(tab)

        if tab.active
          return r()

        chrome.tabs.update(tab.id, {active: true}, r)

    ensureVisibility = (tab) ->
      return if not tab

      new Promise (resolve) ->
        chrome.tabs.executeScript tab.id, {code: code}, (result) ->
          if result and result[0] isnt "visible"
            chrome.windows.getCurrent (window) ->
              chrome.windows.update window.id, {focused: true}, ->
                ## resolve that we did focus the window!
                resolve(true)
          else
            resolve()

    query()
    .then (tabs) ->
      makeActive(tabs[0])
    .then(ensureVisibility)
    .then(fn)

  moveBrowser: (bounds) ->
    chrome.windows.getCurrent (window) ->
      chrome.windows.update(window.id, {
        top: bounds.top
        left: bounds.left
      })

  query: (host, data) ->
    ## query for tabs which match
    ## our expected host
    ## ie: http://localhost:2020/*
    url  = host + "/*"
    code = "var s; (s = document.getElementById('#{data.element}')) && s.textContent"

    query = ->
      new Promise (resolve) ->
        chrome.tabs.query({url: url, windowType: "normal"}, resolve)

    queryTab = (tab) ->
      new Promise (resolve, reject) ->
        chrome.tabs.executeScript tab.id, {code: code}, (result) ->
          if result and result[0] is data.string
            resolve()
          else
            reject(new Error)

    query()
    .then (tabs) ->
      ## generate array of promises
      map(tabs, queryTab)
    .any()

  verify: (data, fn) ->
    @query(HOST, data)
    .then(fn)
}

module.exports = automation
