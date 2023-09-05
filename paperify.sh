#!/bin/sh

if sh "set -o pipefail" > /dev/null 2>&1; then
  set -o pipefail
fi


###############################################################################
# Variables and constants                                                     #
###############################################################################

ORIGINAL_FILE_URL=
OUTPUT_FILE=
FROM_FORMAT=
CHATGPT_TOKEN=
TEMP_DIR="/tmp/paperify"
ARXIV_CAT="math"
NUM_PAPERS="100"
MAX_CONCURRENCY="32"
FIGURE_PROB="25"
EQUATION_PROB="25"
MAX_SIZE="2500000"
MIN_EQUATION_LENGTH="5"
MAX_EQUATION_LENGTH="120"
MIN_CAPTION_LENGTH="20"
CHATGPT_TOPIC="cybersecurity"
QUIET="false"
SKIP_DOWNLOADING="false"
SKIP_REGENERATING_METADATA="false"
SKIP_EXTRACTING="false"
SKIP_FILTERING="false"

CLEAR="$(printf "\033[m")"
RED="$(printf "\033[1m\033[31m")"
ICONV_PARAM="$(
  if printf "test\n" | iconv --unicode-subst . >/dev/null 2>&1; then
    printf "%s\n" "--unicode-subst ."
  else
    printf "%s\n" "-c"
  fi
)"


###############################################################################
# Utility functions                                                           #
###############################################################################

echo() {
  if [ "${#}" -gt 0 ]; then
    printf "%s\n" "${@}"
  else
    printf "\n"
  fi
}

error() {
  printf "${RED}Error:${CLEAR} %s\n" "${@}" >&2
}

error_exit() {
  error "${@}"
  exit 1
}

log() {
  if ! "${QUIET}"; then
    echo "${@}" >&2
  fi
}

worker_wait() {
  while [ "$(jobs -p | wc -l)" -gt "${MAX_CONCURRENCY}" ]; do
    sleep 0.1
  done
}

rand_int() {
  if [ "${#}" -lt 1 ]; then
    < /dev/urandom \
        head -c 4 \
      | od -t uI \
      | head -n 1 \
      | sed 's/  */ /g' \
      | cut -d ' ' -f 2
  else
    # I know that modding random numbers can skew the distribution, but this
    # use case isn't serious enough for me to care.
    echo "$(( $(
      < /dev/urandom \
          head -c 4 \
        | od -t uI \
        | head -n 1 \
        | sed 's/  */ /g' \
        | cut -d ' ' -f 2
    ) % ${1} ))"
  fi
}

check_latex() {
  DIR="$(mktemp -d)"
  echo "${1}" \
    | pandoc \
      --from "markdown" \
      --to latex \
      --template template.tex \
      --output "${DIR}/out.tex" \
      -
  (
    cd "${DIR}" || exit 1
    if ! pdflatex out.tex >/dev/null; then
      exit 1
    fi
  )
  RESULT="${?}"
  rm -rf "${DIR}"
  return "${RESULT}"
}

usage() {
  cat <<EOF
usage: ${0} [OPTIONS] <URL or path> <output file>

OPTIONS:
  --temp-dir <DIR>            Directory for assets (default: ${TEMP_DIR})
  --from-format <FORMAT>      Format of input file (default: input suffix)
  --arxiv-category <CAT>      arXiv.org paper category (default: ${ARXIV_CAT})
  --num-papers <NUM>          Number of papers to download (default: ${NUM_PAPERS})
  --max-concurrency <PROCS>   Maximum simultaneous processes (default: ${MAX_CONCURRENCY})
  --figure-frequency <N>      Chance of a figure is 1/N per paragraph (default: ${FIGURE_PROB})
  --equation-frequency <N>    Chance of an equation is 1/N per paragraph (default: ${EQUATION_PROB})
  --max-size <BYTES>          Max allowed image size in bytes (default ${MAX_SIZE})
  --min-equation-length <N>   Minimum equation length in characters (default ${MIN_EQUATION_LENGTH})
  --max-equation-length <N>   Maximum equation length in characters (default ${MAX_EQUATION_LENGTH})
  --min-caption-length <N>    Minimum figure caption length in characters (default ${MIN_CAPTION_LENGTH})
  --chatgpt-token <TOKEN>     ChatGPT token to generate paper title, abstract, etc.
  --chatgpt-topic <TOPIC>     Paper topic ChatGPT will generate metadta for
  --quiet                     Don't log statuses
  --skip-downloading          Don't download papers from arXiv.org
  --skip-extracting           Don't extract equations and captions
  --skip-metadata             Don't regenerate metadata
  --skip-filtering            Don't filter out large files or non-diagram images
EOF
}

args_required() {
  EXPECTING="${1}"
  shift 1
  if [ "${#}" -le "${EXPECTING}" ]; then 
    error "${1} requires ${EXPECTING} argument$(
      [ "${EXPECTING}" -ge 2 ] && echo 's'
    )"
    echo
    usage
    exit 1
  fi
}


###############################################################################
# Main procedures                                                             #
###############################################################################

check_requirements() {
  for COMMAND in pandoc curl python3 pdflatex jq iconv; do
    if ! command -v "${COMMAND}" >/dev/null 2>&1; then
      error_exit "${COMMAND} must be installed and on the PATH for ${0} to run."
    fi
  done
}

parse_args() {
  while [ "${#}" -gt 0 ]; do
    case "${1}" in
      --temp-dir)
        args_required 1 "${@}"
        TEMP_DIR="${2}"
        shift 1
        ;;
      --from-format)
        args_required 1 "${@}"
        FROM_FORMAT="${2}"
        shift 1
        ;;
      --arxiv-category)
        args_required 1 "${@}"
        ARXIV_CAT="${2}"
        shift 1
        ;;
      --num-papers)
        args_required 1 "${@}"
        NUM_PAPERS="${2}"
        shift 1
        ;;
      --max-concurrency)
        args_required 1 "${@}"
        MAX_CONCURRENCY="${2}"
        shift 1
        ;;
      --figure-frequency)
        args_required 1 "${@}"
        FIGURE_PROB="${2}"
        shift 1
        ;;
      --equation-frequency)
        args_required 1 "${@}"
        EQUATION_PROB="${2}"
        shift 1
        ;;
      --max-size)
        args_required 1 "${@}"
        MAX_SIZE="${2}"
        shift 1
        ;;
      --min-equation-length)
        args_required 1 "${@}"
        MIN_EQUATION_LENGTH="${2}"
        shift 1
        ;;
      --max-equation-length)
        args_required 1 "${@}"
        MAX_EQUATION_LENGTH="${2}"
        shift 1
        ;;
      --min-caption-length)
        args_required 1 "${@}"
        MIN_CAPTION_LENGTH="${2}"
        shift 1
        ;;
      --chatgpt-token)
        args_required 1 "${@}"
        CHATGPT_TOKEN="${2}"
        shift 1
        ;;
      --chatgpt-topic)
        args_required 1 "${@}"
        CHATGPT_TOPIC="${2}"
        shift 1
        ;;
      --quiet)
        QUIET="true"
        ;;
      --skip-downloading)
        SKIP_DOWNLOADING="true"
        ;;
      --skip-extracting)
        SKIP_EXTRACTING="true"
        ;;
      --skip-metadata)
        SKIP_REGENERATING_METADATA="true"
        ;;
      --skip-filtering)
        SKIP_FILTERING="true"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        error "Unrecognized argument '${1}'"
        echo
        usage
        exit 1
        ;;
      *)
        if [ -z "${ORIGINAL_FILE_URL}" ]; then
          ORIGINAL_FILE_URL="${1}"
          if [ -z "${FROM_FORMAT}" ]; then
            FROM_FORMAT="$(
              echo "${ORIGINAL_FILE_URL}" \
                | sed 's/.*\.\(.*\)$/\1/'
            )"
          fi
        elif [ -z "${OUTPUT_FILE}" ]; then
          OUTPUT_FILE="${1}"
        fi
        ;;
    esac
    shift 1
  done

  if [ -z "${ORIGINAL_FILE_URL}" ]; then
    error "URL or file path argument expected."
    echo
    usage
    exit 1
  elif [ -z "${OUTPUT_FILE}" ]; then
    error "Output file argument expected."
    echo
    usage
    exit 1
  fi
}

open_temp_dir() {
  log "Creating directory ${TEMP_DIR} for intermediate work..."
  mkdir -p "${TEMP_DIR}"
  cd "${TEMP_DIR}" || error_exit "could not cd to temp directory ${TEMP_DIR}"
}

dump_latex_template() {
  cat <<"EOF" > template.tex
\PassOptionsToPackage{unicode$for(hyperrefoptions)$,$hyperrefoptions$$endfor$}{hyperref}
\PassOptionsToPackage{hyphens}{url}
$if(colorlinks)$
\PassOptionsToPackage{dvipsnames,svgnames,x11names}{xcolor}
$endif$
$if(dir)$
$if(latex-dir-rtl)$
\PassOptionsToPackage{RTLdocument}{bidi}
$endif$
$endif$
$if(CJKmainfont)$
\PassOptionsToPackage{space}{xeCJK}
$endif$
%
\documentclass[
$if(fontsize)$
  $fontsize$,
$endif$
$if(lang)$
  $babel-lang$,
$endif$
$if(papersize)$
  $papersize$paper,
$endif$
$for(classoption)$
  $classoption$$sep$,
$endfor$
]{$documentclass$}
\usepackage{cite}
\usepackage{amsmath,amssymb,amsfonts}
\usepackage{algorithmic}
$if(fontfamily)$
\usepackage[$for(fontfamilyoptions)$$fontfamilyoptions$$sep$,$endfor$]{$fontfamily$}
$else$
\usepackage{lmodern}
$endif$
$if(linestretch)$
\usepackage{setspace}
$endif$
\usepackage{iftex}
\ifPDFTeX
  \usepackage[$if(fontenc)$$fontenc$$else$T1$endif$]{fontenc}
  \usepackage[utf8]{inputenc}
  \usepackage{textcomp} % provide euro and other symbols
\else % if luatex or xetex
$if(mathspec)$
  \ifXeTeX
    \usepackage{mathspec}
  \else
    \usepackage{unicode-math}
  \fi
$else$
  \usepackage{unicode-math}
$endif$
  \defaultfontfeatures{Scale=MatchLowercase}
  \defaultfontfeatures[\rmfamily]{Ligatures=TeX,Scale=1}
$if(mainfont)$
  \setmainfont[$for(mainfontoptions)$$mainfontoptions$$sep$,$endfor$]{$mainfont$}
$endif$
$if(sansfont)$
  \setsansfont[$for(sansfontoptions)$$sansfontoptions$$sep$,$endfor$]{$sansfont$}
$endif$
$if(monofont)$
  \setmonofont[$for(monofontoptions)$$monofontoptions$$sep$,$endfor$]{$monofont$}
$endif$
$for(fontfamilies)$
  \newfontfamily{$fontfamilies.name$}[$for(fontfamilies.options)$$fontfamilies.options$$sep$,$endfor$]{$fontfamilies.font$}
$endfor$
$if(mathfont)$
$if(mathspec)$
  \ifXeTeX
    \setmathfont(Digits,Latin,Greek)[$for(mathfontoptions)$$mathfontoptions$$sep$,$endfor$]{$mathfont$}
  \else
    \setmathfont[$for(mathfontoptions)$$mathfontoptions$$sep$,$endfor$]{$mathfont$}
  \fi
$else$
  \setmathfont[$for(mathfontoptions)$$mathfontoptions$$sep$,$endfor$]{$mathfont$}
$endif$
$endif$
$if(CJKmainfont)$
  \ifXeTeX
    \usepackage{xeCJK}
    \setCJKmainfont[$for(CJKoptions)$$CJKoptions$$sep$,$endfor$]{$CJKmainfont$}
  \fi
$endif$
$if(luatexjapresetoptions)$
  \ifLuaTeX
    \usepackage[$for(luatexjapresetoptions)$$luatexjapresetoptions$$sep$,$endfor$]{luatexja-preset}
  \fi
$endif$
$if(CJKmainfont)$
  \ifLuaTeX
    \usepackage[$for(luatexjafontspecoptions)$$luatexjafontspecoptions$$sep$,$endfor$]{luatexja-fontspec}
    \setmainjfont[$for(CJKoptions)$$CJKoptions$$sep$,$endfor$]{$CJKmainfont$}
  \fi
$endif$
\fi
$if(zero-width-non-joiner)$
%% Support for zero-width non-joiner characters.
\makeatletter
\def\zerowidthnonjoiner{%
  % Prevent ligatures and adjust kerning, but still support hyphenating.
  \texorpdfstring{%
    \textormath{\nobreak\discretionary{-}{}{\kern.03em}%
      \ifvmode\else\nobreak\hskip\z@skip\fi}{}%
  }{}%
}
\makeatother
\ifPDFTeX
  \DeclareUnicodeCharacter{200C}{\zerowidthnonjoiner}
\else
  \catcode`^^^^200c=\active
  \protected\def ^^^^200c{\zerowidthnonjoiner}
\fi
%% End of ZWNJ support
$endif$
% Use upquote if available, for straight quotes in verbatim environments
\IfFileExists{upquote.sty}{\usepackage{upquote}}{}
\IfFileExists{microtype.sty}{% use microtype if available
  \usepackage[$for(microtypeoptions)$$microtypeoptions$$sep$,$endfor$]{microtype}
  \UseMicrotypeSet[protrusion]{basicmath} % disable protrusion for tt fonts
}{}
$if(indent)$
$else$
\makeatletter
\@ifundefined{KOMAClassName}{% if non-KOMA class
  \IfFileExists{parskip.sty}{%
    \usepackage{parskip}
  }{% else
    \setlength{\parindent}{0pt}
    \setlength{\parskip}{6pt plus 2pt minus 1pt}}
}{% if KOMA class
  \KOMAoptions{parskip=half}}
\makeatother
$endif$
$if(verbatim-in-note)$
\usepackage{fancyvrb}
$endif$
\usepackage{xcolor}
\IfFileExists{xurl.sty}{\usepackage{xurl}}{} % add URL line breaks if available
\IfFileExists{bookmark.sty}{\usepackage{bookmark}}{\usepackage{hyperref}}
\hypersetup{
$if(title-meta)$
  pdftitle={$title-meta$},
$endif$
$if(author-meta)$
  pdfauthor={$author-meta$},
$endif$
$if(lang)$
  pdflang={$lang$},
$endif$
$if(subject)$
  pdfsubject={$subject$},
$endif$
$if(keywords)$
  pdfkeywords={$for(keywords)$$keywords$$sep$, $endfor$},
$endif$
$if(colorlinks)$
  colorlinks=true,
  linkcolor={$if(linkcolor)$$linkcolor$$else$Maroon$endif$},
  filecolor={$if(filecolor)$$filecolor$$else$Maroon$endif$},
  citecolor={$if(citecolor)$$citecolor$$else$Blue$endif$},
  urlcolor={$if(urlcolor)$$urlcolor$$else$Blue$endif$},
$else$
  hidelinks,
$endif$
  pdfcreator={LaTeX via pandoc}}
\urlstyle{same} % disable monospaced font for URLs
$if(verbatim-in-note)$
\VerbatimFootnotes % allow verbatim text in footnotes
$endif$
$if(geometry)$
\usepackage[$for(geometry)$$geometry$$sep$,$endfor$]{geometry}
$endif$
$if(listings)$
\usepackage{listings}
\newcommand{\passthrough}[1]{#1}
\lstset{defaultdialect=[5.3]Lua}
\lstset{defaultdialect=[x86masm]Assembler}
$endif$
$if(lhs)$
\lstnewenvironment{code}{\lstset{language=Haskell,basicstyle=\small\ttfamily}}{}
$endif$
$if(highlighting-macros)$
$highlighting-macros$
$endif$
$if(tables)$
\usepackage{longtable,booktabs,array}

% https://tex.stackexchange.com/a/224096
\makeatletter
\let\oldlt\longtable
\let\endoldlt\endlongtable
\def\longtable{\@ifnextchar[\longtable@i \longtable@ii}
\def\longtable@i[#1]{\begin{figure}[t]
\onecolumn
\begin{minipage}{0.5\textwidth}
\oldlt[#1]
}
\def\longtable@ii{\begin{figure}[t]
\onecolumn
\begin{minipage}{0.5\textwidth}
\oldlt
}
\def\endlongtable{\endoldlt
\end{minipage}
\twocolumn
\end{figure}}
\makeatother


$if(multirow)$
\usepackage{multirow}
$endif$
\usepackage{calc} % for calculating minipage widths
% Correct order of tables after \paragraph or \subparagraph
\usepackage{etoolbox}
\makeatletter
\patchcmd\longtable{\par}{\if@noskipsec\mbox{}\fi\par}{}{}
\makeatother
% Allow footnotes in longtable head/foot
\IfFileExists{footnotehyper.sty}{\usepackage{footnotehyper}}{\usepackage{footnote}}
\makesavenoteenv{longtable}
$endif$
$if(graphics)$
\usepackage{graphicx}
\makeatletter
\def\maxwidth{\ifdim\Gin@nat@width>\linewidth\linewidth\else\Gin@nat@width\fi}
\def\maxheight{\ifdim\Gin@nat@height>\textheight\textheight\else\Gin@nat@height\fi}
\makeatother
% Scale images if necessary, so that they will not overflow the page
% margins by default, and it is still possible to overwrite the defaults
% using explicit options in \includegraphics[width, height, ...]{}
\setkeys{Gin}{width=\maxwidth,height=\maxheight,keepaspectratio}
% Set default figure placement to htbp
\makeatletter
\def\fps@figure{htbp}
\makeatother
$endif$
$if(links-as-notes)$
% Make links footnotes instead of hotlinks:
\DeclareRobustCommand{\href}[2]{#2\footnote{\url{#1}}}
$endif$
$if(strikeout)$
$-- also used for underline
\usepackage[normalem]{ulem}
% Avoid problems with \sout in headers with hyperref
\pdfstringdefDisableCommands{\renewcommand{\sout}{}}
$endif$
\setlength{\emergencystretch}{3em} % prevent overfull lines
\providecommand{\tightlist}{%
  \setlength{\itemsep}{0pt}\setlength{\parskip}{0pt}}
$if(numbersections)$
\setcounter{secnumdepth}{$if(secnumdepth)$$secnumdepth$$else$5$endif$}
$else$
\setcounter{secnumdepth}{-\maxdimen} % remove section numbering
$endif$
$if(block-headings)$
% Make \paragraph and \subparagraph free-standing
\ifx\paragraph\undefined\else
  \let\oldparagraph\paragraph
  \renewcommand{\paragraph}[1]{\oldparagraph{#1}\mbox{}}
\fi
\ifx\subparagraph\undefined\else
  \let\oldsubparagraph\subparagraph
  \renewcommand{\subparagraph}[1]{\oldsubparagraph{#1}\mbox{}}
\fi
$endif$
$if(pagestyle)$
\pagestyle{$pagestyle$}
$endif$
$if(csl-refs)$
\newlength{\cslhangindent}
\setlength{\cslhangindent}{1.5em}
\newlength{\csllabelwidth}
\setlength{\csllabelwidth}{3em}
\newlength{\cslentryspacingunit} % times entry-spacing
\setlength{\cslentryspacingunit}{\parskip}
\newenvironment{CSLReferences}[2] % #1 hanging-ident, #2 entry spacing
 {% dont indent paragraphs
  \setlength{\parindent}{0pt}
  % turn on hanging indent if param 1 is 1
  \ifodd #1
  \let\oldpar\par
  \def\par{\hangindent=\cslhangindent\oldpar}
  \fi
  % set entry spacing
  \setlength{\parskip}{#2\cslentryspacingunit}
 }%
 {}
\usepackage{calc}
\newcommand{\CSLBlock}[1]{#1\hfill\break}
\newcommand{\CSLLeftMargin}[1]{\parbox[t]{\csllabelwidth}{#1}}
\newcommand{\CSLRightInline}[1]{\parbox[t]{\linewidth - \csllabelwidth}{#1}\break}
\newcommand{\CSLIndent}[1]{\hspace{\cslhangindent}#1}
$endif$
$for(header-includes)$
$header-includes$
$endfor$
$if(lang)$
\ifXeTeX
  % Load polyglossia as late as possible: uses bidi with RTL langages (e.g. Hebrew, Arabic)
  \usepackage{polyglossia}
  \setmainlanguage[$for(polyglossia-lang.options)$$polyglossia-lang.options$$sep$,$endfor$]{$polyglossia-lang.name$}
$for(polyglossia-otherlangs)$
  \setotherlanguage[$for(polyglossia-otherlangs.options)$$polyglossia-otherlangs.options$$sep$,$endfor$]{$polyglossia-otherlangs.name$}
$endfor$
\else
  \usepackage[$for(babel-otherlangs)$$babel-otherlangs$,$endfor$main=$babel-lang$]{babel}
% get rid of language-specific shorthands (see #6817):
\let\LanguageShortHands\languageshorthands
\def\languageshorthands#1{}
$if(babel-newcommands)$
  $babel-newcommands$
$endif$
\fi
$endif$
\ifLuaTeX
  \usepackage{selnolig}  % disable illegal ligatures
\fi
$if(dir)$
\ifXeTeX
  % Load bidi as late as possible as it modifies e.g. graphicx
  \usepackage{bidi}
\fi
\ifPDFTeX
  \TeXXeTstate=1
  \newcommand{\RL}[1]{\beginR #1\endR}
  \newcommand{\LR}[1]{\beginL #1\endL}
  \newenvironment{RTL}{\beginR}{\endR}
  \newenvironment{LTR}{\beginL}{\endL}
\fi
$endif$
$if(natbib)$
\usepackage[$natbiboptions$]{natbib}
\bibliographystyle{$if(biblio-style)$$biblio-style$$else$plainnat$endif$}
$endif$
$if(biblatex)$
\usepackage[$if(biblio-style)$style=$biblio-style$,$endif$$for(biblatexoptions)$$biblatexoptions$$sep$,$endfor$]{biblatex}
$for(bibliography)$
\addbibresource{$bibliography$}
$endfor$
$endif$
$if(nocite-ids)$
\nocite{$for(nocite-ids)$$it$$sep$, $endfor$}
$endif$
\usepackage{csquotes}

$if(title)$
\title{$title$$if(thanks)$\thanks{$thanks$}$endif$}
$endif$

\markboth{$if(journal)$$journal$$endif$}{$if(title)$$title$$endif$}

$if(subtitle)$
\usepackage{etoolbox}
\makeatletter
\providecommand{\subtitle}[1]{% add subtitle to \maketitle
  \apptocmd{\@title}{\par {\large #1 \par}}{}{}
}
\makeatother
\subtitle{$subtitle$}
$endif$
\author{$for(author)$$author$$sep$ \and $endfor$}
\date{$date$}

\begin{document}
$if(has-frontmatter)$
\frontmatter
$endif$
$if(title)$
\maketitle
$if(abstract)$
\begin{abstract}
$abstract$
\end{abstract}
$endif$
$endif$

$for(include-before)$
$include-before$

$endfor$
$if(toc)$
$if(toc-title)$
\renewcommand*\contentsname{$toc-title$}
$endif$
{
$if(colorlinks)$
\hypersetup{linkcolor=$if(toccolor)$$toccolor$$else$$endif$}
$endif$
\setcounter{tocdepth}{$toc-depth$}
\tableofcontents
}
$endif$
$if(lof)$
\listoffigures
$endif$
$if(lot)$
\listoftables
$endif$
$if(linestretch)$
\setstretch{$linestretch$}
$endif$
$if(has-frontmatter)$
\mainmatter
$endif$
$body$

$if(has-frontmatter)$
\backmatter
$endif$
$if(natbib)$
$if(bibliography)$
$if(biblio-title)$
$if(has-chapters)$
\renewcommand\bibname{$biblio-title$}
$else$
\renewcommand\refname{$biblio-title$}
$endif$
$endif$
  \bibliography{$for(bibliography)$$bibliography$$sep$,$endfor$}

$endif$
$endif$
$if(biblatex)$
\printbibliography$if(biblio-title)$[title=$biblio-title$]$endif$

$endif$
$for(include-after)$
$include-after$

$endfor$
\end{document}
EOF
}

dump_yaml_template() {
  if "${SKIP_REGENERATING_METADATA}" && [ -f metadata.md ]; then
    return 0
  elif [ -n "${CHATGPT_TOKEN}" ] && ! "${SKIP_REGENERATING_METADATA}"; then
    log "Generating paper metadata with ChatGPT..."
    curl https://api.openai.com/v1/chat/completions \
        --silent \
        --show-error \
        --location \
        --header "Content-Type: application/json" \
        --header "Authorization: Bearer ${CHATGPT_TOKEN}" \
        --data '{
          "model": "gpt-3.5-turbo",
          "messages": [
            {
              "role": "system",
              "content": "You are a JSON generator. You only return valid JSON. You generate JSON with information about realistic scientific research papers for a given topic. A user should be convinced that the paper, its author, and all parts of it are real. The fields in the returned JSON object are: journal_name, thanks, author_name, author_organization, author_email, paper_title, paper_abstract"
            },
            {
              "role": "user",
              "content": "Generate a valid JSON object with metadata about an award-winning research paper related to '"${CHATGPT_TOPIC}"'. Include the journal name, author thanks, author name, author organization, author email, paper title, and paper abstract."
            }
          ]
        }' \
      > chatgpt_response.json
    jq --raw-output '.choices[0].message.content' chatgpt_response.json \
      > metadata.json
    log "Generated metadata for '$(
      jq --raw-output '.paper_title' metadata.json
    )'"
    cat <<EOF > metadata.md
---
documentclass: IEEEtran
classoption:
  - journal
  - letterpaper
journal: |
  $(jq --raw-output '.journal_name' metadata.json)
title: |
  $(jq --raw-output '.paper_title' metadata.json)
thanks: |
  $(jq --raw-output '.thanks' metadata.json)
author: 
  - |
    $(jq --raw-output '.author_name' metadata.json)

    $(jq --raw-output '.author_organization' metadata.json)

    [$(jq --raw-output '.author_email' metadata.json)](mailto:$(jq --raw-output '.author_email' metadata.json))
abstract: |
  $(jq --raw-output '.paper_abstract' metadata.json)
...


EOF
  else
    cat <<"EOF" > metadata.md
---
documentclass: IEEEtran
classoption:
  # - conference
  - journal
  # - compsoc  # Changes a lot of the typefaces
  - letterpaper
journal: |
  International Journal of Cybersecurity Research (IJCR)
title: |
  Adaptive Threat Intelligence Framework for Proactive Cyber Defense
# subtitle: (With a subtitle)
thanks: |
  The authors would like to express their gratitude to the Cybersecurity
  Research Institute (CRI) for providing valuable resources and support
  during the research process
author: 
  - |
    Emily Collins, PhD

    Cybersecurity Institute for Advanced Research (CIAR)

    [`ecollins@ciar.org`](mailto:ecollins@ciar.org)
abstract: |
  In this paper, we present a novel approach for detecting advanced persistent
  threats (APTs) using deep learning techniques. APTs pose significant
  challenges to traditional security systems due to their stealthy and
  persistent nature. Our proposed method leverages a combination of
  convolutional neural networks and recurrent neural networks to analyze
  large-scale network traffic data. We introduce a novel attention mechanism
  that identifies subtle patterns in the data, enabling the detection of APTs
  with high accuracy. Experimental results on real-world datasets demonstrate
  the effectiveness of our approach in identifying previously unknown APTs
  while minimizing false positives. The framework offers a promising solution
  for enhancing the security posture of modern network infrastructures against
  sophisticated cyber threats.
...


EOF
  fi
}

download_papers() {
  if "${SKIP_DOWNLOADING}"; then
    return 0
  fi
  log "Downloading papers..."
  mkdir -p images
  mkdir -p tex
  mkdir -p unknown_files
  (
    cd images || error_exit "could not cd to $(pwd)/images"
    # This little pipeline is some of the most egregious code I've ever
    # written. But sometimes you have to shit the bed to remind yourself how
    # clean sheets feel. Greetz to Haskell Curry.
    curl \
        --silent \
        --show-error \
        --location \
        "https://arxiv.org/list/${ARXIV_CAT}/current?skip=0&show=${NUM_PAPERS}" \
      | grep --only-matching 'href="/format/[^"]*"' \
      | sed 's,href="/format/\(.*\)",https://arxiv.org/e-print/\1,' \
      | (
        while read -r URL; do \
          worker_wait
          curl \
              --silent \
              --show-error \
              --location \
              "${URL}" \
            | python3 -c 'import base64, gzip, io, os, sys, tarfile; exec(
                "def _try(attempt, _except):\n"
                "  try:\n"
                "    return attempt()\n"
                "  except Exception as e:\n"
                "    return _except(e)"
              ), (
                lambda ext: lambda rand: lambda data: (
                  lambda _filter: lambda randname:
                    _try(
                      lambda: (
                        lambda f: list(
                          open(
                            randname(member.name),
                            "wb",
                          ).write(
                            f.extractfile(member).read()
                          )
                          for member in f.getmembers()
                          if _filter(member)
                        ) 
                      )( # f
                        tarfile.open(mode="r", fileobj=data)
                      ),
                      lambda e: (
                        _try(
                          lambda: (
                            data.seek(0),
                            open(
                              randname("gzipped.tex"),
                              "wb",
                            ).write(
                              gzip.decompress(data.read())
                            )
                          ),
                          lambda _e: (
                            print("Exception", e, _e),
                            open(
                              os.path.join("..", "unknown_files", rand(24)), "wb"
                            ).write(
                              (data.seek(0), data.read(), data.seek(0))[1]
                            )
                          )
                        )
                      ),
                    )
                )( # _filter
                  lambda m:
                    m if (
                      not (m.name.startswith("..") or m.name.startswith("/"))
                      and m.isfile()
                      and ext(m.name) in {
                        "jpg", 
                        "jpeg", 
                        "png",
                        "tex",
                      }
                    ) else None
                )( # randname
                  lambda f:
                    f"./{rand(24)}.{ext(f)}"
                )
              )( # ext
                lambda s: 
                  os.path.splitext(s)[1][1:].lower()
              )( # rand
                lambda n: 
                  base64.b64encode(
                    open("/dev/urandom", "rb").read(n),
                    altchars=b"__",
                  ).decode("ascii")
              )( # data
                io.BytesIO(sys.stdin.buffer.read())
              )' &
        done
        wait
      )
    mv ./*.tex ../tex/
  )
}

deduplicate() {
  if "${SKIP_DOWNLOADING}"; then
    return 0
  fi
  # *nix users born after 1993 don't know how to use awk. All they know is
  # charge they phone, lay massive amounts of pipe, eat hot chip, and lie.
  for d in ./*; do
    if [ -d "${d}" ]; then
      (
        cd "${d}" || error_exit "could not cd to $(pwd)/${d}"
        log "Deduplicating $(pwd)..."
        sha256sum ./* > hashes.txt 2>/dev/null
        < hashes.txt \
            cut -d ' ' -f 1 \
          | sort \
          | uniq -c \
          | sort -n \
          | sed 's/^ *//g' \
          | grep '^\([2-9]\|[0-9][0-9]\)' \
          | cut -d ' ' -f 2 \
          | (
            while read -r HASH; do
              < hashes.txt \
                  grep --fixed-strings "${HASH}" \
                | head -n -1 \
                | sed 's/  */ /g' \
                | cut -d ' ' -f 2 \
                | xargs rm -vf
            done
          )
        rm -f hashes.txt
      )
    fi
  done
}

filter_large_files() {
  if "${SKIP_FILTERING}"; then
    return 0
  fi
  log "Removing images greater than ${MAX_SIZE} bytes..."
  mkdir -p big_images
  (
    cd images || error_exit "could not cd to $(pwd)/images"
    du --bytes ./* \
      | awk '$1 > '"${MAX_SIZE}"' { print $2 }' \
      | xargs -I {} mv {} ../big_images/
  )
}

filter_diagrams() {
  if ! command -v convert >/dev/null 2>&1 || "${SKIP_FILTERING}"; then
    return 0
  fi
  # Use a rough heuristic to pick out diagram-ish images: the top left and
  # bottom right corners must be approximately white (or transparent)
  log "Removing non-diagram images..."
  mkdir -p non_diagram_images
  (
    cd images || error_exit "could not cd to $(pwd)/images"
    TOTAL="$(find . -type f | wc -l)"
    NUM="0"
    for IMAGE in ./*; do
      worker_wait
      (
        convert \
            "${IMAGE}" \
            -format \
            "%[fx:u.p{0,0}.a == 0 ? 999 : u.p{0,0}.r * 255 + u.p{0,0}.g * 255 + u.p{0,0}.b * 255]\n%[fx:u.p{w,h}.a == 0 ? 999 : u.p{w,h}.r * 255 + u.p{w,h}.g * 255 + u.p{w,h}.b * 255]\n" \
            "info:" \
          | (
            while read -r PIXEL_SUM; do
              if [ -z "${PIXEL_SUM}" ] || [ "${PIXEL_SUM}" -lt 750 ]; then
                mv "${IMAGE}" ../non_diagram_images/
                break
              fi
            done
          )
      ) &
      NUM="$(( NUM + 1 ))"
      if ! "${QUIET}"; then
        printf "\r%s%% complete..." "$(( 100 * NUM / TOTAL ))" >&2
      fi
    done
    wait
    echo
  )
}

extract_captions() {
  if "${SKIP_EXTRACTING}"; then
    return 0
  fi
  log "Generating and testing figure captions..."
  cat tex/* \
    | grep --only-matching '\\caption{[^\{]\+}' \
    | sed 's,\\caption{,,g' \
    | sed 's,}$,,g' \
    > unchecked_captions.txt
  < unchecked_captions.txt \
    sort \
    | uniq \
    | grep '.\{'"${MIN_CAPTION_LENGTH}"',\}' \
    | shuf \
    | (
      TOTAL="$(wc -l < unchecked_captions.txt)"
      NUM="0"
      while read -r CAPTION; do
        worker_wait
        (check_latex "${CAPTION}" && echo "${CAPTION}") &
        NUM="$(( NUM + 1 ))"
        if ! "${QUIET}"; then
          printf "\r%s%% complete..." "$(( 100 * NUM / TOTAL ))" >&2
        fi
      done
      wait
      echo
    ) \
    > captions.txt
}

extract_equations() {
  if "${SKIP_EXTRACTING}"; then
    return 0
  fi
  log "Generating and testing equations..."
  cat tex/* \
    | grep --only-matching '^\$\$.*\$\$$' \
    | sort \
    | uniq \
    | grep '^\$\$ *.\{'"${MIN_EQUATION_LENGTH},${MAX_EQUATION_LENGTH}"'\} *\$\$$' \
    | shuf \
    | (
      while read -r EQUATION; do
        worker_wait
        (check_latex "${EQUATION}" && echo "${EQUATION}") &
      done
      wait
    ) \
    > equations.txt
}

build_paper() {
  if ! echo "${ORIGINAL_FILE_URL}" | grep '\.\(html\|php\)$' >/dev/null \
      && ! echo "${ORIGINAL_FILE_URL}" | grep 'http.*\/[^.]*$' >/dev/null; then
    # Pandoc cannot download e.g. epub files, but it must download web-based
    # files itself to correctly pull media and rewrite URLs for images. In this
    # case, we download non-HTML on its behalf.
    log "Downloading input file..."
    curl \
      --silent \
      --show-error \
      --location \
      --output "input.${FROM_FORMAT}" \
      "${ORIGINAL_FILE_URL}"
    ORIGINAL_FILE_URL="input.${FROM_FORMAT}"
  fi

  log "Building paper..."
  pandoc \
      --from "${FROM_FORMAT}" \
      --to "gfm" \
      --wrap none \
      --extract-media media \
      --output - \
      "${ORIGINAL_FILE_URL}" \
    | grep -v 'cover\.\(jpe\?g\|png\)' \
    | grep -v '!\[.*\](.*\.\(svg\|gif\))' \
    | (
      while read -r LINE; do 
        echo "${LINE}"
        if [ "$(rand_int "${FIGURE_PROB}")" = 1 ]; then 
          printf "\n\n![%s](%s)\n\n" "$(
            < captions.txt \
                shuf \
              | head -n 1
          )" "$(
            find images -type f \
              | shuf \
              | head -n 1
          )"
        elif [ "$(rand_int "${EQUATION_PROB}")" = 1 ]; then 
          printf "\n\n%s\n\n" "$(
            < equations.txt \
                shuf \
              | head -n 1
          )"
        fi
      done
    ) \
    | cat metadata.md - \
    | iconv \
        --from-code utf-8 \
        --to-code ascii//translit \
        ${ICONV_PARAM} \
    | pandoc \
        --from "markdown" \
        --to latex \
        --template template.tex \
        --output output.tex \
        -
  pdflatex output.tex
}

check_requirements
parse_args "${@}"
(
  open_temp_dir  # Changes the working directory to $TEMP_DIR
  dump_latex_template
  dump_yaml_template
  download_papers
  deduplicate
  filter_large_files
  filter_diagrams
  deduplicate
  extract_captions
  extract_equations
  build_paper
)
cp "${TEMP_DIR}/output.pdf" "${OUTPUT_FILE}"

