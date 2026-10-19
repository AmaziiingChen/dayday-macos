(() => {
  if (window.__daydayLivePreviewInstalled === true) {
    return;
  }

  const { EditorView, Decoration, ViewPlugin, WidgetType } = MarkEdit.codemirror.view;
  const { ChangeSet, Transaction } = MarkEdit.codemirror.state;
  const { syntaxTree } = MarkEdit.codemirror.language;

  let livePreviewEnabled = true;
  let selectedAttachmentID;
  let compositionActive = false;
  let compositionFinalizing = false;
  let compositionSession;
  let previewRefreshRequested = false;
  let previewRefreshDeferred = false;
  let previewRefreshTimer;
  let previewRefreshIdleCallback;
  let previewRefreshGeneration = 0;
  let geometryRefreshTimer;

  const editorRoot = document.documentElement;
  editorRoot.style.setProperty('--dayday-accent', 'rgba(0, 122, 255, 1)');
  editorRoot.style.setProperty('--dayday-accent-muted', 'rgba(0, 122, 255, 0.24)');
  editorRoot.style.setProperty('--dayday-accent-subtle', 'rgba(0, 122, 255, 0.14)');
  editorRoot.style.setProperty('--dayday-scroll-thumb', 'rgba(0, 122, 255, 0.28)');
  editorRoot.style.setProperty('--dayday-scroll-thumb-hover', 'rgba(0, 122, 255, 0.52)');
  editorRoot.style.setProperty('--dayday-placeholder', 'rgba(99, 99, 102, 0.82)');

  // MarkEdit's bundled syntax themes intentionally carry their own blue/orange palette. Dayday
  // preserves syntax colours for code, but the writing grammar follows the user's app accent.
  const themeOverrides = document.createElement('style');
  themeOverrides.id = 'dayday-markdown-theme';
  themeOverrides.textContent = `
    .cm-editor .cm-md-header:not(.cm-md-quote),
    .cm-editor .cm-md-listMark,
    .cm-editor .cm-md-link,
    .cm-editor .cm-md-linkMark,
    .cm-editor .cm-md-quoteMark,
    .cm-editor .cm-md-taskMarker,
    .cm-editor .cm-md-horizontalRule {
      color: var(--dayday-accent) !important;
      text-shadow: none !important;
    }
    .cm-editor .cm-cursor,
    .cm-editor .cm-dropCursor {
      border-left-color: var(--dayday-accent) !important;
    }
    .cm-editor.cm-focused .cm-selectionBackground,
    .cm-editor .cm-selectionBackground,
    .cm-editor .cm-content ::selection {
      background-color: var(--dayday-accent-subtle) !important;
    }
    .cm-content[data-dayday-empty="true"]::before {
      color: var(--dayday-placeholder);
      content: attr(data-dayday-placeholder);
      position: absolute;
      top: 6px;
      left: 0;
      right: 0;
      pointer-events: none;
      white-space: normal;
      font: 400 18px/1.62 -apple-system, BlinkMacSystemFont, sans-serif;
    }
  `;
  document.head.appendChild(themeOverrides);

  const postJournalMessage = (action, payload = {}) => {
    const handler = window.webkit?.messageHandlers?.daydayJournal;
    if (handler !== undefined) {
      handler.postMessage({ action, ...payload });
    }
  };

  class AttachmentWidget extends WidgetType {
    constructor(id, altText, isSelected) {
      super();
      this.id = id;
      this.altText = altText;
      this.isSelected = isSelected;
    }

    eq(other) {
      return other.id === this.id
        && other.altText === this.altText
        && other.isSelected === this.isSelected;
    }

    toDOM(view) {
      const figure = document.createElement('figure');
      figure.className = 'dayday-journal-image';
      figure.dataset.attachmentId = this.id;
      figure.tabIndex = 0;
      figure.setAttribute('role', 'group');
      figure.setAttribute('aria-label', this.altText.length > 0 ? this.altText : '日记图片');
      if (this.isSelected) {
        figure.classList.add('is-selected');
      }

      const image = document.createElement('img');
      image.src = `dayday-attachment://${this.id}`;
      image.alt = this.altText;
      image.draggable = false;
      image.addEventListener('load', () => view.requestMeasure());
      figure.appendChild(image);

      const removeButton = document.createElement('button');
      removeButton.className = 'dayday-journal-image-remove';
      removeButton.type = 'button';
      removeButton.title = '删除图片';
      removeButton.setAttribute('aria-label', '删除图片');
      removeButton.textContent = '×';
      removeButton.addEventListener('mousedown', event => {
        event.preventDefault();
        event.stopPropagation();
      });
      removeButton.addEventListener('click', event => {
        event.preventDefault();
        event.stopPropagation();
        postJournalMessage('removeAttachment', { id: this.id });
      });
      figure.appendChild(removeButton);

      const select = event => {
        if (event.target === removeButton) {
          return;
        }
        event.preventDefault();
        selectedAttachmentID = this.id;
        postJournalMessage('selectAttachment', { id: this.id });
        previewRefreshRequested = true;
        view.dispatch({});
        view.focus();
      };
      figure.addEventListener('mousedown', select);
      figure.addEventListener('keydown', event => {
        if (event.key === 'Backspace' || event.key === 'Delete') {
          event.preventDefault();
          postJournalMessage('removeAttachment', { id: this.id });
        } else if (event.key === 'Enter' || event.key === ' ') {
          select(event);
        }
      });
      return figure;
    }

    ignoreEvent() {
      return true;
    }
  }

  class HorizontalRuleWidget extends WidgetType {
    toDOM() {
      const rule = document.createElement('hr');
      rule.className = 'dayday-journal-rule';
      rule.setAttribute('aria-label', '分隔线');
      return rule;
    }
  }

  const markerNames = new Set([
    'HeaderMark',
    'EmphasisMark',
    'QuoteMark',
    'CodeMark',
  ]);

  const selectionInside = (state, from, to) => state.selection.ranges.some(range => {
    if (!range.empty) {
      return range.from < to && range.to > from;
    }
    return range.head > from && range.head < to;
  });

  const activeLineContains = (state, position) => {
    const line = state.doc.lineAt(Math.min(Math.max(position, 0), state.doc.length));
    return state.selection.ranges.some(range => range.from <= line.to && range.to >= line.from);
  };

  const parentNamed = (node, name) => {
    for (let parent = node.node.parent; parent !== null; parent = parent.parent) {
      if (parent.name === name) {
        return true;
      }
    }
    return false;
  };

  const attachment = source => {
    const match = source.match(/^!\[((?:\\.|[^\]])*)\]\(dayday-attachment:\/\/([0-9a-f-]{36})\)$/i);
    if (match === null) {
      return undefined;
    }
    return {
      altText: match[1].replace(/\\([\\\]])/g, '$1'),
      id: match[2].toLowerCase(),
    };
  };

  const buildDecorations = view => {
    if (!livePreviewEnabled) {
      return Decoration.none;
    }

    const decorations = [];
    const state = view.state;
    for (const visibleRange of view.visibleRanges) {
      syntaxTree(state).iterate({
        from: visibleRange.from,
        to: visibleRange.to,
        enter(node) {
          if (node.name === 'Image') {
            const item = attachment(state.sliceDoc(node.from, node.to));
            if (item !== undefined && !selectionInside(state, node.from, node.to)) {
              decorations.push(Decoration.replace({
                widget: new AttachmentWidget(
                  item.id,
                  item.altText,
                  selectedAttachmentID === item.id
                ),
              }).range(node.from, node.to));
              return false;
            }
          }

          if (node.name === 'HorizontalRule' && !activeLineContains(state, node.from)) {
            decorations.push(Decoration.replace({
              widget: new HorizontalRuleWidget(),
            }).range(node.from, node.to));
            return false;
          }

          const isLinkDestination = node.name === 'URL' && parentNamed(node, 'Link');
          const isLinkMark = node.name === 'LinkMark';
          if ((markerNames.has(node.name) || isLinkDestination || isLinkMark)
            && !activeLineContains(state, node.from)) {
            decorations.push(Decoration.replace({}).range(node.from, node.to));
          }
          return true;
        },
      });
    }
    return Decoration.set(decorations, true);
  };

  const livePreview = ViewPlugin.fromClass(class {
    constructor(view) {
      this.decorations = buildDecorations(view);
    }

    update(update) {
      if (compositionActive || compositionFinalizing || previewRefreshDeferred || update.view.composing) {
        // Keep existing ranges valid without reparsing Markdown while the input method mutates
        // marked text. A single full rebuild happens after composition ends.
        if (update.docChanged) {
          this.decorations = this.decorations.map(update.changes);
        }
        if (update.docChanged || update.selectionSet || update.viewportChanged) {
          previewRefreshRequested = true;
        }
        return;
      }

      if (previewRefreshRequested || update.docChanged || update.selectionSet) {
        cancelGeometryRefresh();
        if (update.selectionSet && selectedAttachmentID !== undefined) {
          selectedAttachmentID = undefined;
          postJournalMessage('clearAttachmentSelection');
        }
        previewRefreshRequested = false;
        this.decorations = buildDecorations(update.view);
      } else if (update.geometryChanged) {
        // A native inspector transition changes the WKWebView width many times in a few hundred
        // milliseconds. Rebuilding syntax-aware decorations for every intermediate width makes
        // the transition progressively slower as the document grows. Keep the existing valid
        // ranges while the geometry is moving and rebuild once after it settles.
        scheduleGeometryRefresh(update.view);
      } else if (update.viewportChanged) {
        // Scrolling changes which document ranges need Live Preview decorations and should remain
        // immediate. It is intentionally separate from geometry-only window resizing.
        cancelGeometryRefresh();
        this.decorations = buildDecorations(update.view);
      }
    }
  }, {
    decorations: value => value.decorations,
  });

  const updatePlaceholderVisibility = view => {
    view.contentDOM.dataset.daydayEmpty = view.state.doc.length === 0 ? 'true' : 'false';
  };

  // Placeholder visibility stays inside the editor transaction. It therefore disappears on the
  // first provisional or committed character without crossing WebKit -> SwiftUI during an IME
  // composition and without waiting for the 1.5 second persistence checkpoint.
  const placeholderVisibility = ViewPlugin.fromClass(class {
    constructor(view) {
      updatePlaceholderVisibility(view);
    }

    update(update) {
      if (update.docChanged) {
        updatePlaceholderVisibility(update.view);
      }
    }
  });

  const cancelDeferredPreviewRefresh = () => {
    previewRefreshGeneration += 1;
    if (previewRefreshTimer !== undefined) {
      clearTimeout(previewRefreshTimer);
      previewRefreshTimer = undefined;
    }
    if (previewRefreshIdleCallback !== undefined
      && typeof window.cancelIdleCallback === 'function') {
      window.cancelIdleCallback(previewRefreshIdleCallback);
      previewRefreshIdleCallback = undefined;
    }
  };

  const cancelGeometryRefresh = () => {
    if (geometryRefreshTimer !== undefined) {
      clearTimeout(geometryRefreshTimer);
      geometryRefreshTimer = undefined;
    }
  };

  const scheduleGeometryRefresh = view => {
    cancelGeometryRefresh();
    geometryRefreshTimer = setTimeout(() => {
      geometryRefreshTimer = undefined;
      if (window.editor !== view) {
        return;
      }
      if (compositionActive || compositionFinalizing || view.composing) {
        previewRefreshRequested = true;
        return;
      }
      previewRefreshRequested = true;
      view.dispatch({});
    }, 140);
  };

  const scheduleDeferredPreviewRefresh = view => {
    cancelDeferredPreviewRefresh();
    previewRefreshDeferred = true;
    const generation = previewRefreshGeneration;
    previewRefreshTimer = setTimeout(() => {
      previewRefreshTimer = undefined;
      const refresh = () => {
        previewRefreshIdleCallback = undefined;
        if (generation !== previewRefreshGeneration
          || compositionActive
          || compositionFinalizing
          || view.composing
          || window.editor !== view) {
          return;
        }
        previewRefreshDeferred = false;
        view.dispatch({});
      };

      if (typeof window.requestIdleCallback === 'function') {
        previewRefreshIdleCallback = window.requestIdleCallback(refresh, { timeout: 500 });
      } else {
        previewRefreshTimer = setTimeout(refresh, 32);
      }
    }, 450);
  };

  const compositionGuard = EditorView.domEventHandlers({
    compositionstart(_event, view) {
      cancelDeferredPreviewRefresh();
      compositionActive = true;
      compositionFinalizing = false;
      previewRefreshDeferred = true;
      compositionSession = {
        changes: ChangeSet.empty(view.state.doc.length),
      };
      return false;
    },
    compositionend(_event, view) {
      const session = compositionSession ?? {
        changes: ChangeSet.empty(view.state.doc.length),
      };
      compositionSession = session;
      compositionFinalizing = true;
      previewRefreshRequested = true;

      // Let WebKit paint the committed word first. Preview decorations are rebuilt only after a
      // genuine typing pause; a following Pinyin session cancels and inherits this refresh.
      requestAnimationFrame(() => {
        reportCommittedChanges(session.changes);

        // A fast typist may already be composing the next word by the time this runs. That newer
        // session owns the shared flags and will schedule one trailing preview refresh.
        if (compositionSession !== session || view.composing || window.editor !== view) {
          return;
        }
        compositionSession = undefined;
        compositionActive = false;
        compositionFinalizing = false;
        scheduleDeferredPreviewRefresh(view);
      });
      return false;
    },
  });

  const journalTheme = EditorView.theme({
    '&': {
      height: '100%',
      backgroundColor: 'transparent',
    },
    '.cm-scroller': {
      overflow: 'auto',
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      boxSizing: 'border-box',
      justifyContent: 'center',
      padding: '0 34px',
      scrollbarWidth: 'thin',
      scrollbarColor: 'var(--dayday-scroll-thumb) transparent',
    },
    '.cm-scroller::-webkit-scrollbar': {
      width: '8px',
      height: '8px',
    },
    '.cm-scroller::-webkit-scrollbar-track': {
      background: 'transparent',
    },
    '.cm-scroller::-webkit-scrollbar-thumb': {
      minHeight: '36px',
      border: '2px solid transparent',
      borderRadius: '999px',
      backgroundColor: 'var(--dayday-scroll-thumb)',
      backgroundClip: 'padding-box',
    },
    '.cm-scroller::-webkit-scrollbar-thumb:hover': {
      backgroundColor: 'var(--dayday-scroll-thumb-hover)',
    },
    '.cm-content': {
      flex: '0 1 792px',
      minHeight: '100%',
      width: '100%',
      minWidth: '0',
      maxWidth: '792px',
      boxSizing: 'border-box',
      position: 'relative',
      margin: '0',
      padding: '6px 0 45vh 0',
    },
    '.cm-line': {
      padding: '0',
    },
    '.cm-md-header': {
      letterSpacing: '-0.012em',
    },
    '.dayday-journal-image': {
      boxSizing: 'border-box',
      display: 'inline-flex',
      position: 'relative',
      maxWidth: 'min(100%, 620px)',
      margin: '0.7em 0',
      padding: '0',
      border: '2px solid transparent',
      borderRadius: '12px',
      background: 'transparent',
      overflow: 'hidden',
      verticalAlign: 'top',
      outline: 'none',
    },
    '.dayday-journal-image:hover, .dayday-journal-image:focus, .dayday-journal-image.is-selected': {
      borderColor: 'var(--dayday-accent-muted)',
    },
    '.dayday-journal-image img': {
      display: 'block',
      maxWidth: '100%',
      maxHeight: '420px',
      width: 'auto',
      height: 'auto',
      objectFit: 'contain',
      borderRadius: '10px',
    },
    '.dayday-journal-image-remove': {
      position: 'absolute',
      top: '8px',
      right: '8px',
      width: '26px',
      height: '26px',
      padding: '0',
      border: 'none',
      borderRadius: '13px',
      color: 'white',
      background: 'rgba(20, 20, 22, 0.72)',
      font: '600 18px/24px -apple-system, BlinkMacSystemFont, sans-serif',
      opacity: '0',
      cursor: 'default',
    },
    '.dayday-journal-image:hover .dayday-journal-image-remove, .dayday-journal-image:focus .dayday-journal-image-remove, .dayday-journal-image-remove:focus': {
      opacity: '1',
    },
    '.dayday-journal-rule': {
      display: 'inline-block',
      width: '100%',
      height: '1px',
      margin: '0.75em 0 0.35em',
      border: 'none',
      background: 'var(--dayday-accent-muted)',
      verticalAlign: 'middle',
    },
  });

  const refreshPreview = () => {
    cancelGeometryRefresh();
    cancelDeferredPreviewRefresh();
    previewRefreshDeferred = false;
    previewRefreshRequested = true;
    if (typeof window.editor?.dispatch === 'function') {
      window.editor.dispatch({});
    }
  };

  MarkEdit.addExtension([
    compositionGuard,
    placeholderVisibility,
    livePreview,
    journalTheme,
  ]);
  window.daydayJournalRefreshPreview = refreshPreview;
  window.daydayJournalSetLivePreview = enabled => {
    livePreviewEnabled = enabled === true;
    selectedAttachmentID = undefined;
    refreshPreview();
  };
  window.daydayJournalSetTheme = theme => {
    if (theme === null || typeof theme !== 'object') {
      return;
    }
    const values = {
      '--dayday-accent': theme.accent,
      '--dayday-accent-muted': theme.accentMuted,
      '--dayday-accent-subtle': theme.accentSubtle,
      '--dayday-scroll-thumb': theme.scrollThumb,
      '--dayday-scroll-thumb-hover': theme.scrollThumbHover,
      '--dayday-placeholder': theme.placeholder,
    };
    Object.entries(values).forEach(([name, value]) => {
      if (typeof value === 'string' && value.length <= 64) {
        editorRoot.style.setProperty(name, value);
      }
    });
  };
  window.daydayJournalSetPlaceholder = placeholder => {
    if (typeof placeholder !== 'string' || placeholder.length > 240) {
      return;
    }
    window.editor.contentDOM.dataset.daydayPlaceholder = placeholder;
    updatePlaceholderVisibility(window.editor);
  };
  window.__daydayLivePreviewInstalled = true;
  document.documentElement.dataset.daydayLivePreview = 'ready';
})();
