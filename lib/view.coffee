{Task, CompositeDisposable, Emitter} = require 'atom'
{$, View} = require 'atom-space-pen-views'

Pty = require.resolve './process'
Terminal = require 'term.js'
InputDialog = null

path = require 'path'
os = require 'os'

lastOpenedView = null
lastActiveElement = null

module.exports =
class TerminationView extends View
  animating: false
  id: 'terminal-window-container'
  maximized: false
  opened: false
  pwd: ''
  windowHeight: $(window).height()
  windowWidth: $(window).width()
  rowHeight: 20
  rowWidth: 300
  shell: ''
  tabView: false

  @content: ->
    @div class: 'termination terminal-view when', outlet: 'terminationView', =>
      @div class: 'panel-divider', outlet: 'panelDivider'
      @div class: 'btn-toolbar', outlet:'toolbar', =>
        @button outlet: 'closeBtn', class: 'btn inline-block-tight right', click: 'destroy', =>
          @span class: 'icon icon-x'
        @button outlet: 'hideBtn', class: 'btn inline-block-tight right', click: 'hide', =>
          @span class: 'icon icon-chevron-down'
        @button outlet: 'maximizeBtn', style:'display:none', class: 'btn inline-block-tight right', click: 'maximize', =>
          @span class: 'icon icon-screen-full'
        @button outlet: 'inputBtn', class: 'btn inline-block-tight left', click: 'inputDialog', =>
          @span class: 'icon icon-keyboard'
      @div class: 'xterm', outlet: 'xterm'

  @getFocusedTerminal: ->
    return Terminal.Terminal.focus

  initialize: (@id, @pwd, @statusIcon, @statusBar, @shell, @args=[], @autoRun=[]) ->
    @subscriptions = new CompositeDisposable
    @emitter = new Emitter

    @subscriptions.add atom.tooltips.add @closeBtn,
      title: 'Close'
    @subscriptions.add atom.tooltips.add @hideBtn,
      title: 'Hide'
    @subscriptions.add @maximizeBtn.tooltip = atom.tooltips.add @maximizeBtn,
      title: 'Fullscreen'
    @inputBtn.tooltip = atom.tooltips.add @inputBtn,
      title: 'Insert Text'

    @prevWidth = atom.config.get('termination.style.defaultPanelWidth')
    if @prevWidth.indexOf('%') > 0
      percent = Math.abs(Math.min(parseFloat(@prevWidth) / 100.0, 1))
      rightHeight = $('atom-panel.right').children(".terminal-view").width() or 0
      @prevWidth = percent * ($('.item-views').width() + rightHeight)
    @xterm.height 0

    @setAnimationSpeed()
    @subscriptions.add atom.config.onDidChange 'termination.style.animationSpeed', @setAnimationSpeed

    override = (event) ->
      return if event.originalEvent.dataTransfer.getData('termination') is 'true'
      event.preventDefault()
      event.stopPropagation()

    @xterm.on 'mouseup', (event) =>
      if event.which != 3
        text = window.getSelection().toString()
        atom.clipboard.write(text) if atom.config.get('platformio-ide-terminal.toggles.selectToCopy') and text
        unless text
          @focus()
    @xterm.on 'dragenter', override
    @xterm.on 'dragover', override
    @xterm.on 'drop', @recieveItemOrFile

    @on 'focus', @focus
    @subscriptions.add dispose: =>
      @off 'focus', @focus

  attach: ->
    return if @panel?
    @panel = atom.workspace.addRightPanel(item: this, visible: false)

  setAnimationSpeed: =>
    @animationSpeed = atom.config.get('termination.style.animationSpeed')
    @animationSpeed = 100 if @animationSpeed is 0

    @xterm.css 'transition', "width #{0.25 / @animationSpeed}s linear"

  recieveItemOrFile: (event) =>
    event.preventDefault()
    event.stopPropagation()
    {dataTransfer} = event.originalEvent

    if dataTransfer.getData('atom-event') is 'true'
      filePath = dataTransfer.getData('text/plain')
      @input "#{filePath} " if filePath
    else if filePath = dataTransfer.getData('initialPath')
      @input "#{filePath} "
    else if dataTransfer.files.length > 0
      for file in dataTransfer.files
        @input "#{file.path} "

  forkPtyProcess: ->
    Task.once Pty, path.resolve(@pwd), @shell, @args, =>
      @input = ->
      @resize = ->

  getId: ->
    return @id

  displayTerminal: ->
    {cols, rows} = @getDimensions()
    @ptyProcess = @forkPtyProcess()

    @terminal = new Terminal {
      cursorBlink     : false
      scrollback      : atom.config.get 'termination.core.scrollback'
      cols, rows
    }

    @attachListeners()
    @attachResizeEvents()
    @attachWindowEvents()
    @terminal.open @xterm.get(0)

  attachListeners: ->
    @ptyProcess.on "termination:data", (data) =>
      @terminal.write data

    @ptyProcess.on "termination:exit", =>
      @destroy() if atom.config.get('termination.toggles.autoClose')

    @terminal.end = => @destroy()

    @terminal.on "data", (data) =>
      @input data

    @ptyProcess.on "termination:title", (title) =>
      @process = title
    @terminal.on "title", (title) =>
      @title = title

    @terminal.once "open", =>
      @applyStyle()
      @resizeTerminalToView()

      return unless @ptyProcess.childProcess?
      autoRunCommand = atom.config.get('termination.core.autoRunCommand')
      @input "#{autoRunCommand}#{os.EOL}" if autoRunCommand
      @input "#{command}#{os.EOL}" for command in @autoRun

  destroy: ->
    @subscriptions.dispose()
    @statusIcon.destroy()
    @statusBar.removeTerminalView this
    @detachResizeEvents()
    @detachWindowEvents()

    if @panel.isVisible()
      @hide()
      @onTransitionEnd => @panel.destroy()
    else
      @panel.destroy()

    if @statusIcon and @statusIcon.parentNode
      @statusIcon.parentNode.removeChild(@statusIcon)

    @ptyProcess?.terminate()
    @terminal?.destroy()

  maximize: ->
    @subscriptions.remove @maximizeBtn.tooltip
    @maximizeBtn.tooltip.dispose()

    @maxWidth = @prevWidth + $('.item-views').width()
    btn = @maximizeBtn.children('span')
    @onTransitionEnd => @focus()

    if @maximized
      @maximizeBtn.tooltip = atom.tooltips.add @maximizeBtn,
        title: 'Fullscreen'
      @subscriptions.add @maximizeBtn.tooltip
      @adjustWidth @prevWidth
      btn.removeClass('icon-screen-normal').addClass('icon-screen-full')
      @maximized = false
    else
      @maximizeBtn.tooltip = atom.tooltips.add @maximizeBtn,
        title: 'Normal'
      @subscriptions.add @maximizeBtn.tooltip
      @adjustWidth @prevWidth
      btn.removeClass('icon-screen-full').addClass('icon-screen-normal')
      @maximized = true

  open: =>
    lastActiveElement ?= $(document.activeElement)

    if lastOpenedView and lastOpenedView != this
      if lastOpenedView.maximized
        @subscriptions.remove @maximizeBtn.tooltip
        @maximizeBtn.tooltip.dispose()
        icon = @maximizeBtn.children('span')

        @maxWidth = lastOpenedView.maxWidth
        @maximizeBtn.tooltip = atom.tooltips.add @maximizeBtn,
          title: 'Normal'
        @subscriptions.add @maximizeBtn.tooltip
        icon.removeClass('icon-screen-full').addClass('icon-screen-normal')
        @maximized = true
      lastOpenedView.hide()

    lastOpenedView = this
    @statusBar.setActiveTerminalView this
    @statusIcon.activate()

    @onTransitionEnd =>
      if not @opened
        @opened = true
        @displayTerminal()
        @prevWidth = @nearestRow(@xterm.width())
        @xterm.width(@prevWidth)
      else
        @focus()

    @panel.show()
    @xterm.width 0
    @animating = true
    @xterm.width if @maximized then @maxWidth else @prevWidth

  hide: =>
    @terminal?.blur()
    lastOpenedView = null
    @statusIcon.deactivate()
    @onTransitionEnd =>
      @panel.hide()
      unless lastOpenedView?
        if lastActiveElement?
          lastActiveElement.focus()
          lastActiveElement = null

    @xterm.width if @maximized then @maxWidth else @prevWidth
    @animating = true
    @xterm.width 0

  toggle: ->
    return if @animating

    if @panel.isVisible()
      @hide()
    else
      @open()

  input: (data) ->
    return unless @ptyProcess.childProcess?

    @terminal.stopScrolling()
    @ptyProcess.send event: 'input', text: data

  resize: (cols, rows) ->
    return unless @ptyProcess.childProcess?

    @ptyProcess.send {event: 'resize', rows, cols}

  applyStyle: ->
    config = atom.config.get 'termination'

    @xterm.addClass config.style.theme
    @xterm.addClass 'cursor-blink' if config.toggles.cursorBlink

    editorFont = atom.config.get('editor.fontFamily')
    defaultFont = "Menlo, Consolas, 'DejaVu Sans Mono', monospace"
    overrideFont = config.style.fontFamily
    @terminal.element.style.fontFamily = overrideFont or editorFont or defaultFont

    @subscriptions.add atom.config.onDidChange 'editor.fontFamily', (event) =>
      editorFont = event.newValue
      @terminal.element.style.fontFamily = overrideFont or editorFont or defaultFont
    @subscriptions.add atom.config.onDidChange 'termination.style.fontFamily', (event) =>
      overrideFont = event.newValue
      @terminal.element.style.fontFamily = overrideFont or editorFont or defaultFont

    editorFontSize = atom.config.get('editor.fontSize')
    overrideFontSize = config.style.fontSize
    @terminal.element.style.fontSize = "#{overrideFontSize or editorFontSize}px"

    @subscriptions.add atom.config.onDidChange 'editor.fontSize', (event) =>
      editorFontSize = event.newValue
      @terminal.element.style.fontSize = "#{overrideFontSize or editorFontSize}px"
      @resizeTerminalToView()
    @subscriptions.add atom.config.onDidChange 'termination.style.fontSize', (event) =>
      overrideFontSize = event.newValue
      @terminal.element.style.fontSize = "#{overrideFontSize or editorFontSize}px"
      @resizeTerminalToView()

    # first 8 colors i.e. 'dark' colors
    @terminal.colors[0..7] = [
      config.ansiColors.normal.black.toHexString()
      config.ansiColors.normal.red.toHexString()
      config.ansiColors.normal.green.toHexString()
      config.ansiColors.normal.yellow.toHexString()
      config.ansiColors.normal.blue.toHexString()
      config.ansiColors.normal.magenta.toHexString()
      config.ansiColors.normal.cyan.toHexString()
      config.ansiColors.normal.white.toHexString()
    ]
    # 'bright' colors
    @terminal.colors[8..15] = [
      config.ansiColors.zBright.brightBlack.toHexString()
      config.ansiColors.zBright.brightRed.toHexString()
      config.ansiColors.zBright.brightGreen.toHexString()
      config.ansiColors.zBright.brightYellow.toHexString()
      config.ansiColors.zBright.brightBlue.toHexString()
      config.ansiColors.zBright.brightMagenta.toHexString()
      config.ansiColors.zBright.brightCyan.toHexString()
      config.ansiColors.zBright.brightWhite.toHexString()
    ]

  attachWindowEvents: ->
    $(window).on 'resize', @onWindowResize

  detachWindowEvents: ->
    $(window).off 'resize', @onWindowResize

  attachResizeEvents: ->
    @panelDivider.on 'mousedown', @resizeStarted

  detachResizeEvents: ->
    @panelDivider.off 'mousedown'

  onWindowResize: =>
    if not @tabView
      @xterm.css 'transition', ''
      newWidth = $(window).width()
      rightPanel = $('atom-panel-container.right').first().get(0)
      overflow = rightPanel.scrollWidth - rightPanel.offsetWidth

      delta = newWidth - @windowWidth
      @windowWidth = newWidth

      if @maximized
        clamped = Math.max(@maxWidth + delta, @rowWidth)

        @adjustWidth clamped if @panel.isVisible()
        @maxWidth = clamped

        @prevWidth = Math.min(@prevWidth, @maxWidth)
      else if overflow > 0
        clamped = Math.max(@nearestRow(@prevWidth + delta), @rowWidth)

        @adjustWidth clamped if @panel.isVisible()
        @prevWidth = clamped

      @xterm.css 'transition', "width #{0.25 / @animationSpeed}s linear"
    @resizeTerminalToView()

  resizeStarted: =>
    return if @maximized
    @maxWidth = @prevWidth + $('.item-views').width()
    $(document).on('mousemove', @resizePanel)
    $(document).on('mouseup', @resizeStopped)
    @xterm.css 'transition', ''

  resizeStopped: =>
    $(document).off('mousemove', @resizePanel)
    $(document).off('mouseup', @resizeStopped)
    @xterm.css 'transition', "width #{0.25 / @animationSpeed}s linear"

  nearestRow: (value) ->
    rows = value // @rowWidth
    return rows * @rowWidth

  resizePanel: (event) =>
    return @resizeStopped() unless event.which is 1

    mouseX = $(window).width() - event.pageX
    delta = mouseX - $('atom-panel-container.right').width()
    clamped = Math.max(@nearestRow(@prevWidth + delta), @rowWidth)
    return if clamped > @maxWidth

    @xterm.width clamped
    $(@terminal.element).width clamped
    @prevWidth = clamped

    @resizeTerminalToView()

  adjustWidth: (width) ->
    @xterm.width width
    $(@terminal.element).width width

  copy: ->
    if @terminal._selected
      textarea = @terminal.getCopyTextarea()
      text = @terminal.grabText(
        @terminal._selected.x1, @terminal._selected.x2,
        @terminal._selected.y1, @terminal._selected.y2)
    else
      rawText = @terminal.context.getSelection().toString()
      rawLines = rawText.split(/\r?\n/g)
      lines = rawLines.map (line) ->
        line.replace(/\s/g, " ").trimRight()
      text = lines.join("\n")
    atom.clipboard.write text

  paste: ->
    @input atom.clipboard.read()

  copyAllToNewFile: ->
    text = @terminal.lines.map (line) ->
      line.map (cols) -> cols[1]
      .join('').trimRight() + '\n'
    .join('') + '\n'

    atom.workspace.open().then (editor) ->
      editor.insertText(text)

  insertSelection: (customText) ->
    return unless editor = atom.workspace.getActiveTextEditor()
    runCommand = atom.config.get('termination.toggles.runInsertedText')
    selectionText = ''
    if selection = editor.getSelectedText()
      @terminal.stopScrolling()
      selectionText = selection
    else if cursor = editor.getCursorBufferPosition()
      line = editor.lineTextForBufferRow(cursor.row)
      @terminal.stopScrolling()
      selectionText = line
      editor.moveDown(1);
    @input "#{customText.
      replace(/\$L/, "#{editor.getCursorBufferPosition().row + 1}").
      replace(/\$F/, path.basename(editor?.buffer?.file?.path)).
      replace(/\$D/, path.dirname(editor?.buffer?.file?.path)).
      replace(/\$S/, selectionText).
      replace(/\$\$/, '$')}#{if runCommand then os.EOL else ''}"

  focus: =>
    @resizeTerminalToView()
    @focusTerminal()
    @statusBar.setActiveTerminalView(this)
    super()

  blur: =>
    @blurTerminal()
    super()

  focusTerminal: =>
    return unless @terminal

    @terminal.focus()
    if @terminal._textarea
      @terminal._textarea.focus()
    else
      @terminal.element.focus()

  blurTerminal: =>
    return unless @terminal

    @terminal.blur()
    @terminal.element.blur()

  resizeTerminalToView: ->
    return unless @panel.isVisible() or @tabView

    {cols, rows} = @getDimensions()
    return unless cols > 0 and rows > 0
    return unless @terminal
    return if @terminal.rows is rows and @terminal.cols is cols

    @resize cols, rows
    @terminal.resize cols, rows

  getDimensions: ->
    fakeRow = $("<div><span>&nbsp;</span></div>")

    if @terminal
      @find('.terminal').append fakeRow
      fakeCol = fakeRow.children().first()[0].getBoundingClientRect()
      cols = Math.floor @xterm.width() / (fakeCol.width or 9)
      rows = Math.floor @xterm.height() / (fakeCol.height or 20)
      @rowWidth = fakeCol.width
      fakeRow.remove()
    else
      cols = Math.floor @xterm.width() / 9
      rows = Math.floor @xterm.height() / 20

    {cols, rows}

  onTransitionEnd: (callback) ->
    @xterm.one 'webkitTransitionEnd', =>
      callback()
      @animating = false

  inputDialog: ->
    InputDialog ?= require('./input-dialog')
    dialog = new InputDialog this
    dialog.attach()

  rename: ->
    @statusIcon.rename()

  toggleTabView: ->
    if @tabView
      @panel = atom.workspace.addRightPanel(item: this, visible: false)
      @attachResizeEvents()
      @closeBtn.show()
      @hideBtn.show()
      @maximizeBtn.show()
      @tabView = false
    else
      @panel.destroy()
      @detachResizeEvents()
      @closeBtn.hide()
      @hideBtn.hide()
      @maximizeBtn.hide()
      @xterm.css "height", ""
      @tabView = true
      lastOpenedView = null if lastOpenedView == this

  getTitle: ->
    @statusIcon.getName() or "termination"

  getIconName: ->
    "terminal"

  getShell: ->
    return path.basename @shell

  getShellPath: ->
    return @shell

  emit: (event, data) ->
    @emitter.emit event, data

  onDidChangeTitle: (callback) ->
    @emitter.on 'did-change-title', callback

  getPath: ->
    return @getTerminalTitle()

  getTerminalTitle: ->
    return @title or @process

  getTerminal: ->
    return @terminal

  isAnimating: ->
    return @animating
