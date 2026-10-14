#if os(iOS)
//
//  ReadiumNavigatorJS+Selection.swift
//  Books & Vocab
//

import Foundation

extension ReadiumNavigatorJS {
    static func buildSelectionScript(isDebugMode: String) -> String {
        """
        // 監聽原生的文字選取狀態
        document.addEventListener('selectionchange', function() {
            var sel = window.getSelection();
            var isSelecting = sel.rangeCount > 0 && !sel.isCollapsed;
            if (window.__lastIsSelecting !== isSelecting) {
                window.__lastIsSelecting = isSelecting;
                window.webkit.messageHandlers.selectionState.postMessage(isSelecting ? 'active' : 'inactive');
            }
        });

        function dismissActiveSelection() {
            window.getSelection().removeAllRanges();
            window.webkit.messageHandlers.wordDeselect.postMessage('deselect');
        }

        function getDistanceToRect(x, y, rect) {
            var dx = Math.max(rect.left - x, 0, x - rect.right);
            var dy = Math.max(rect.top - y, 0, y - rect.bottom);
            return Math.sqrt(dx * dx + dy * dy);
        }

        function drawDebugBox(rect, isSuccess, isDebug) {
            if (!isDebug) return;
            var box = document.createElement('div');
            box.className = 'debug-hit-box ' + (isSuccess ? 'success' : 'fail');
            box.style.left = (rect.left + window.scrollX) + 'px';
            box.style.top = (rect.top + window.scrollY) + 'px';
            box.style.width = rect.width + 'px';
            box.style.height = rect.height + 'px';
            document.body.appendChild(box);
        }

        function clearDebugMarkers(isDebug, event) {
            document.querySelectorAll('.debug-tap-point, .debug-hit-box').forEach(function(el) {
                el.remove();
            });

            if (!isDebug) return;
            var dot = document.createElement('div');
            dot.className = 'debug-tap-point';
            dot.style.left = (event.clientX + window.scrollX) + 'px';
            dot.style.top = (event.clientY + window.scrollY) + 'px';
            document.body.appendChild(dot);
        }

        function unwrapActiveElement(el) {
            if (el.classList.contains('vocab-word') || el.classList.contains('debug-word-box')) {
                el.classList.remove('active-word');
                return;
            }

            var parent = el.parentNode;
            while (el.firstChild) parent.insertBefore(el.firstChild, el);
            parent.removeChild(el);
            parent.normalize();
        }

        function clearExistingActiveWords() {
            document.querySelectorAll('.active-word').forEach(function(el) {
                unwrapActiveElement(el);
            });
        }

        function findContextContainer(startEl) {
            var container = startEl;
            while (container) {
                var tag = (container.tagName || '').toUpperCase();
                if (tag === 'P' || tag === 'LI' || tag === 'BLOCKQUOTE' || tag === 'TD'
                    || tag === 'DIV' || tag === 'SECTION') return container;
                if (tag === 'BODY') return container;
                container = container.parentElement;
            }
            return null;
        }

        // Offset of (node, index) inside container.textContent; -1 when unavailable.
        function textOffsetInContainer(container, node, index) {
            try {
                var r = document.createRange();
                r.selectNodeContents(container);
                r.setEnd(node, index);
                return r.toString().length;
            } catch (err) { return -1; }
        }

        // Occurrence of needle in haystack closest to hint (first occurrence when hint < 0).
        function nearestIndexOf(haystack, needle, hint) {
            var best = -1;
            var pos = haystack.indexOf(needle);
            while (pos >= 0) {
                if (best < 0 || Math.abs(pos - hint) < Math.abs(best - hint)) best = pos;
                if (hint < 0 || pos > hint) break;
                pos = haystack.indexOf(needle, pos + 1);
            }
            return best;
        }

        // tapOffset: index of the tapped word within the context container text (-1 = unknown).
        function extractContextFromElement(startEl, word, tapOffset) {
            var container = findContextContainer(startEl);
            var fullText = container ? container.textContent : (startEl ? startEl.textContent : word);
            var rawText = fullText;
            fullText = fullText.trim();
            var hint = -1;
            if (typeof tapOffset === 'number' && tapOffset >= 0) {
                hint = Math.max(0, tapOffset - (rawText.length - rawText.replace(/^\\s+/, '').length));
            }

            // Use Intl.Segmenter for locale-aware sentence splitting (Safari 14.1+)
            var sentences;
            if (typeof Intl !== 'undefined' && Intl.Segmenter) {
                var lang = document.documentElement.lang || navigator.language || 'en';
                var segmenter = new Intl.Segmenter(lang, { granularity: 'sentence' });
                sentences = Array.from(segmenter.segment(fullText), function(s) { return s.segment; });
            } else {
                // Fallback: split on CJK/Western sentence terminators and newlines
                sentences = fullText.split(/(?<=[.!?。！？])\\s*|(?<=\\n)/);
                sentences = sentences.filter(function(s) { return s.trim().length > 0; });
            }

            if (!sentences || sentences.length <= 1) {
                if (fullText.length <= 300) return fullText;
                var wordPos = nearestIndexOf(fullText.toLowerCase(), word.toLowerCase(), hint);
                if (wordPos < 0) wordPos = Math.floor(fullText.length / 2);
                var start = Math.max(0, wordPos - 150);
                var end = Math.min(fullText.length, wordPos + word.length + 150);
                return fullText.substring(start, end).trim();
            }

            var wordLower = word.toLowerCase();
            var targetIdx = -1;
            var firstMatch = -1;
            var cursor = 0;
            var starts = [];
            for (var i = 0; i < sentences.length; i++) {
                var sStart = fullText.indexOf(sentences[i], cursor);
                if (sStart < 0) sStart = cursor;
                starts.push(sStart);
                cursor = sStart + sentences[i].length;
                if (sentences[i].toLowerCase().indexOf(wordLower) < 0) continue;
                if (firstMatch < 0) firstMatch = i;
                if (hint >= sStart && hint < cursor) { targetIdx = i; break; }
            }
            if (targetIdx < 0) targetIdx = firstMatch;
            if (targetIdx < 0) return fullText.substring(0, 300).trim();

            // Return: previous sentence + target sentence + next sentence
            var from = Math.max(0, targetIdx - 1);
            var to = Math.min(sentences.length, targetIdx + 2);
            var result = '';
            for (var j = from; j < to; j++) {
                result += sentences[j];
            }
            result = result.trim();

            // Hard cap at 500 chars (word-centered)
            if (result.length > 500) {
                var wp = nearestIndexOf(result.toLowerCase(), wordLower, hint >= 0 ? hint - starts[from] : -1);
                if (wp < 0) wp = Math.floor(result.length / 2);
                var s = Math.max(0, wp - 200);
                var e = Math.min(result.length, wp + word.length + 200);
                result = result.substring(s, e).trim();
            }

            return result;
        }

        function buildWordRangeFromPoint(event) {
            var range = document.caretRangeFromPoint(event.clientX, event.clientY);
            if (!range) return null;

            var textNode = range.startContainer;
            if (textNode.nodeType !== Node.TEXT_NODE) return null;

            var text = textNode.textContent;
            var offset = range.startOffset;
            var wordCharacter = /[\\p{L}\\p{M}\\p{N}'-]/u;
            var start = offset;
            while (start > 0 && wordCharacter.test(text[start - 1])) start--;
            var end = offset;
            while (end < text.length && wordCharacter.test(text[end])) end++;

            var word = text.slice(start, end).replace(/^['-]+|['-]+$/g, '');
            if (word.length < 2) return null;

            var wordRange = document.createRange();
            wordRange.setStart(textNode, start);
            wordRange.setEnd(textNode, end);
            return {
                textNode: textNode,
                text: text,
                start: start,
                word: word,
                range: wordRange,
                rect: wordRange.getBoundingClientRect()
            };
        }

        function activateWordRange(wordData) {
            try {
                var parentEl = wordData.textNode.parentElement;
                if (parentEl && (parentEl.classList.contains('vocab-word') || parentEl.classList.contains('debug-word-box'))) {
                    parentEl.classList.add('active-word');
                } else {
                    var span = document.createElement('span');
                    span.className = 'active-word';
                    try {
                        wordData.range.surroundContents(span);
                    } catch (e) {
                        // surroundContents 在 range 跨元素邊界時拋（此處 range 限單一
                        // text node 理論上不會發生，保留 fallback）：改用 extractContents
                        // 重組，能處理部分選取邊界。
                        span.appendChild(wordData.range.extractContents());
                        wordData.range.insertNode(span);
                    }
                }
            } catch (err) {}
        }

        // 單字點擊偵測（只回應使用者產生的 click；腳本合成的事件不觸發）
        document.addEventListener('click', function(e) {
            if (!e.isTrusted) return;
            if (e.target.closest('a')) return;

            var isDebug = \(isDebugMode);
            var maxHitDistance = 12.0; // 允許的最大點擊誤差（px）

            clearDebugMarkers(isDebug, e);

            // 檢查是否點擊的是已經 active-word 的元素（toggle off）
            var clickedActive = e.target.closest('.active-word');
            if (clickedActive) {
                var dist = getDistanceToRect(e.clientX, e.clientY, clickedActive.getBoundingClientRect());
                if (dist > maxHitDistance) {
                    dismissActiveSelection();
                    return;
                }

                unwrapActiveElement(clickedActive);
                dismissActiveSelection();
                return;
            }

            clearExistingActiveWords();

            // ★ 優先偵測：點擊位置是否在 .vocab-word 內（片語優先）
            var vocabSpan = e.target.closest('.vocab-word');
            if (vocabSpan) {
                var rect = vocabSpan.getBoundingClientRect();
                var dist = getDistanceToRect(e.clientX, e.clientY, rect);
                
                if (dist <= maxHitDistance) {
                    drawDebugBox(rect, true, isDebug);
                    var vocabWord = (vocabSpan.getAttribute('data-word') || vocabSpan.textContent).trim();
                    if (vocabWord.length >= 2) {
                        vocabSpan.classList.add('active-word');
                        window.webkit.messageHandlers.wordTap.postMessage(
                            JSON.stringify({
                                word: vocabWord,
                                context: extractContextFromElement(vocabSpan.parentElement, vocabWord,
                                    textOffsetInContainer(findContextContainer(vocabSpan.parentElement), vocabSpan, 0))
                            })
                        );
                        return;
                    }
                } else {
                    drawDebugBox(rect, false, isDebug);
                }
            }

            // 處理一般文字點擊 (Caret Range 吸附)
            var wordData = buildWordRangeFromPoint(e);
            if (!wordData) {
                dismissActiveSelection();
                return;
            }

            // 判斷落點與單字外框的距離
            var dist = getDistanceToRect(e.clientX, e.clientY, wordData.rect);
            console.log('Distance: ' + dist);

            if (dist > maxHitDistance) {
                drawDebugBox(wordData.rect, false, isDebug);
                dismissActiveSelection();
                return;
            }
            
            // 距離在容許範圍內 -> 成功觸發選取
            drawDebugBox(wordData.rect, true, isDebug);
            activateWordRange(wordData);

            window.webkit.messageHandlers.wordTap.postMessage(
                JSON.stringify({
                    word: wordData.word,
                    context: extractContextFromElement(wordData.textNode.parentElement, wordData.word,
                        textOffsetInContainer(findContextContainer(wordData.textNode.parentElement), wordData.textNode, wordData.start))
                })
            );
        }, true);
        """
    }
}
#endif
