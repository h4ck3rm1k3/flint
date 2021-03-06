// Copyright (c) 2014- Facebook
// License: Boost License 1.0, http://boost.org/LICENSE_1_0.txt
// @author Andrei Alexandrescu (andrei.alexandrescu@facebook.com)

import std.algorithm, std.array, std.ascii, std.conv, std.exception, std.path,
  std.range, std.stdio, std.string;
import Tokenizer, FileCategories;

bool c_mode;

/*
 * Errors vs. Warnings vs. Advice:
 *
 *   Lint errors will be raised regardless of whether the line was
 *   edited in the change.  Warnings will be ignored by Arcanist
 *   unless the change actually modifies the line the warning occurs
 *   on.  Advice is even weaker than a warning.
 *
 *   Please select errors vs. warnings intelligently.  Too much spam
 *   on lines you don't touch reduces the value of lint output.
 *
 */

void lintError(CppLexer.Token tok, const string error) {
  stderr.writef("%.*s(%u): %s",
                cast(uint) tok.file_.length, tok.file_,
                cast(uint) tok.line_,
                error);
}

void lintWarning(CppLexer.Token tok, const string warning) {
  // The FbcodeCppLinter just looks for the text "Warning" in the
  // message.
  lintError(tok, "Warning: " ~ warning);
}

void lintAdvice(CppLexer.Token tok, string advice) {
  // The FbcodeCppLinter just looks for the text "Advice" in the
  // message.
  lintError(tok, "Advice: " ~ advice);
}

bool atSequence(Range)(Range r, const CppLexer.TokenType2[] list...) {
  foreach (t; list) {
    if (r.empty || t != r.front.type_) {
      return false;
    }
    r.popFront;
  }
  return true;
}

// Remove the double quotes or <'s from an included path.
string getIncludedPath(string p) {
  return p[1 .. p.length - 1];
}

/*
 * Skips a template parameter list or argument list, somewhat
 * heuristically.  Basically, scans forward tracking nesting of <>
 * brackets and parenthesis to find the end of the list. This function
 * takes as input an iterator as well as an optional parameter containsArray
 * that is set to true if the outermost nest contains an array
 *
 * Known unsupported case: TK_RSHIFT can end a template instantiation
 * in C++0x as if it were two TK_GREATERs.
 * (E.g. vector<vector<int>>.)
 *
 * Returns: iterator pointing to the final TK_GREATER (or TK_EOF if it
 * didn't finish).
 */
R skipTemplateSpec(R)(R r, bool* containsArray = null) {
  assert(r.front.type_ == tk!"<");

  uint angleNest = 1;
  uint parenNest = 0;

  if (containsArray) {
    *containsArray = false;
  }

  r.popFront;
  for (; r.front.type_ != tk!"\0"; r.popFront) {
    if (r.front.type_ == tk!"(") {
      ++parenNest;
      continue;
    }
    if (r.front.type_ == tk!")") {
      --parenNest;
      continue;
    }

    // Ignore angles inside of parens.  This avoids confusion due to
    // integral template parameters that use < and > as comparison
    // operators.
    if (parenNest > 0) {
      continue;
    }

    if (r.front.type_ == tk!"[") {
      if (angleNest == 1 && containsArray) {
        *containsArray = true;
      }
      continue;
    }

    if (r.front.type_ == tk!"<") {
      ++angleNest;
      continue;
    }
    if (r.front.type_ == tk!">") {
      if (!--angleNest) {
        break;
      }
      continue;
    }
  }

  return r;
}

/*
 * Returns whether `it' points to a token that is a reserved word for
 * a built in type.
 */
bool atBuiltinType(R)(R it) {
  return it.front.type_.among(tk!"double", tk!"float", tk!"int", tk!"short",
      tk!"unsigned", tk!"long", tk!"signed", tk!"void", tk!"bool", tk!"wchar_t",
      tk!"char") != 0;
}

/*
 * heuristically read a potentially namespace-qualified identifier,
 * advancing `it' in the process.
 *
 * Returns: a vector of all the identifier values involved, or an
 * empty vector if no identifier was detected.
 */
string[] readQualifiedIdentifier(R)(ref R it) {
  string[] result;
  for (; it.front.type_.among(tk!"identifier", tk!"::"); it.popFront) {
    if (it.front.type_ == tk!"identifier") {
      result ~= it.front.value_;
    }
  }
  return result;
}

/*
 * starting from a left curly brace, skips until it finds the matching
 * (balanced) right curly brace. Does not care about whether other characters
 * within are balanced.
 *
 * Returns: iterator pointing to the final TK_RCURL (or TK_EOF if it
 * didn't finish).
 */
R skipBlock(R)(R r) {
  enforce(r.front.type_ == tk!"{");

  uint openBraces = 1;

  r.popFront;
  for (; r.front.type_ != tk!"\0"; r.popFront) {
    if (r.front.type_ == tk!"{") {
      ++openBraces;
      continue;
    }
    if (r.front.type_ == tk!"}") {
      if (!--openBraces) {
        break;
      }
      continue;
    }
  }

  return r;
}

/*
 * Iterates through to find all class declarations and calls the callback
 * with an iterator pointing to the first token in the class declaration.
 * The iterator is guaranteed to have type TK_CLASS, TK_STRUCT, or TK_UNION.
 *
 * Note: The callback function is responsible for the scope of its search, as
 * the vector of tokens passed may (likely will) extend past the end of the
 * class block.
 *
 * Returns the sum of the results from calling the callback on
 * each declaration.
 */
uint iterateClasses(alias callback)(Token[] v) {
  uint result = 0;

  for (auto it = v; !it.empty; it.popFront) {
    if (it.atSequence(tk!"template", tk!"<")) {
      it.popFront;
      it = skipTemplateSpec(it);
      continue;
    }

    if (it.front.type_.among(tk!"class", tk!"struct", tk!"union")) {
      result += callback(it, v);
    }
  }

  return result;
}

/*
 * Starting from a function name or one of its arguments, skips the entire
 * function prototype or function declaration (including function body).
 *
 * Implementation is simple: stop at the first semicolon, unless an opening
 * curly brace is found, in which case we stop at the matching closing brace.
 *
 * Returns: iterator pointing to the final TK_RCURL or TK_SEMICOLON, or TK_EOF
 * if it didn't finish.
 */
R skipFunctionDeclaration(R)(R r) {
  r.popFront;
  for (; r.front.type_ != tk!"\0"; r.popFront) {
    if (r.front.type_ == tk!";") { // prototype
      break;
    } else if (r.front.type_ == tk!"{") { // full declaration
      r = skipBlock(r);
      break;
    }
  }
  return r;
}

/**
 * Represent an argument or the name of a function.
 * first is an iterator that points to the start of the argument.
 * last is an iterator that points to the token right after the end of the
 * argument.
 */
struct Argument {
  Token[] tox;
  ref Token first() { return tox.front; }
  ref Token last() { return tox.back; }
}

string formatArg(Argument arg) {
  string result;
  foreach (i, a; arg.tox) {
    if (i != 0 && !a.precedingWhitespace_.empty) {
      result ~= ' ';
    }
    result ~= a.value;
  }
  return result;
}

string formatFunction(Argument functionName, Argument[] args) {
  auto result = formatArg(functionName) ~ "(";
  foreach (i; 0 .. args.length) {
    if (i > 0) {
      result ~= ", ";
    }
    result ~= formatArg(args[i]);
  }
  result ~= ")";
  return result;
}

/**
 * Get the list of arguments of a function, assuming that the current
 * iterator is at the open parenthesis of the function call. After the
 * this method is called, the iterator will be moved to after the end
 * of the function call.
 * @param i: the current iterator, must be at the open parenthesis of the
 * function call.
 * @param args: the arguments of the function would be push to the back of args
 * @return true if (we believe) that there was no problem during the run and
 * false if we believe that something was wrong (most probably with skipping
 * template specs.)
 */
bool getRealArguments(ref Token[] r, ref Argument[] args) {
  assert(r.front.type_ == tk!"(", text(r));
  // the first argument starts after the open parenthesis
  auto argStart = r[1 .. $];
  int parenCount = 1;
  do {
    if (r.front.type_ == tk!"\0") {
      // if we meet EOF before the closing parenthesis, something must be wrong
      // with the template spec skipping
      return false;
    }
    r.popFront;
    switch (r.front.type_.id) {
    case tk!"(".id: parenCount++;
                    break;
    case tk!")".id: parenCount--;
                    break;
    case tk!"<".id:   // This is a heuristic which would fail when < is used with
                    // the traditional meaning in an argument, e.g.
                    //  memset(&foo, a < b ? c : d, sizeof(foo));
                    // but currently we have no way to distinguish that use of
                    // '<' and
                    //  memset(&foo, something<A,B>(a), sizeof(foo));
                    // We include this heuristic in the hope that the second
                    // use of '<' is more common than the first.
                    r = skipTemplateSpec(r);
                    break;
    case tk!",".id:  if (parenCount == 1) {
                      // end an argument of the function we are looking at
                      args ~=
                        Argument(argStart[0 .. argStart.length - r.length]);
                      argStart = r[1 .. $];
                    }// otherwise we are in an inner function, so do nothing
                    break;
    default:        break;
    }
  } while (parenCount != 0);
  if (argStart !is r) {
    args ~= Argument(argStart[0 .. argStart.length - r.length]);
  }
  return true;
}

/**
 * Get the argument list of a function, with the first argument being the
 * function name plus the template spec.
 * @param i: the current iterator, must be at the function name. At the end of
 * the method, i will be pointing at the close parenthesis of the function call
 * @param functionName: the function name will be stored here
 * @param args: the arguments of the function would be push to the back of args
 * @return true if (we believe) that there was no problem during the run and
 * false if we believe that something was wrong (most probably with skipping
 * template specs.)
 */
bool getFunctionNameAndArguments(ref Token[] r, ref Argument functionName,
    ref Argument[] args) {
  auto r1 = r;
  r.popFront;
  if (r.front.type_ == tk!"<") {
    assert(0);
    r = skipTemplateSpec(r);
    if (r.front.type_ == tk!"\0") {
      return false;
    }
    r.popFront;
  }
  functionName.tox = r1[0 .. r1.length - r.length];
  return getRealArguments(r, args);
}

uint checkInitializeFromItself(string fpath, Token[] tokens) {
  auto firstInitializer = [
    tk!":", tk!"identifier", tk!"(", tk!"identifier", tk!")"
  ];
  auto nthInitialier = [
    tk!",", tk!"identifier", tk!"(", tk!"identifier", tk!")"
  ];

  uint result = 0;
  for (auto it = tokens; !it.empty; it.popFront) {
    if (it.atSequence(firstInitializer) || it.atSequence(nthInitialier)) {
      it.popFront;
      auto outerIdentifier = it.front;
      it.popFrontN(2);
      auto innerIdentifier = it.front;
      bool isMember = outerIdentifier.value_.back == '_'
        || outerIdentifier.value_.startsWith("m_");
      if (isMember && outerIdentifier.value_ == innerIdentifier.value_) {
        lintError(outerIdentifier, text(
          "Looks like you're initializing class member [",
          outerIdentifier.value_, "] with itself.\n")
        );
        ++result;
      }
    }
  }
  return result;
}

/**
 * Lint check: check for blacklisted sequences of tokens.
 */
uint checkBlacklistedSequences(string fpath, CppLexer.Token[] v) {
  struct BlacklistEntry {
    CppLexer.TokenType2[] tokens;
    string descr;
    bool cpponly;
  };

  const static BlacklistEntry[] blacklist = [
    BlacklistEntry([tk!"volatile"],
      "'volatile' does not make your code thread-safe. If multiple threads are "
      "sharing data, use std::atomic or locks. In addition, 'volatile' may "
      "force the compiler to generate worse code than it could otherwise. "
      "For more about why 'volatile' doesn't do what you think it does, see "
      "http://fburl.com/volatile or http://www.kernel.org/doc/Documentation/"
      "volatile-considered-harmful.txt.\n",
                   true), // C++ only.
  ];

  const static CppLexer.TokenType2[][] exceptions = [
    [CppLexer.tk!"asm", CppLexer.tk!"volatile"],
  ];

  uint result = 0;
  bool isException = false;

  foreach (i; 0 .. v.length) {
    foreach (e; exceptions) {
      if (atSequence(v[i .. $], e)) { isException = true; break; }
    }
    foreach (ref entry; blacklist) {
      if (!atSequence(v[i .. $], entry.tokens)) { continue; }
      if (isException) { isException = false; continue; }
      if (c_mode && entry.cpponly == true) { continue; }
      lintWarning(v[i], entry.descr);
      ++result;
    }
  }

  return result;
}

uint checkBlacklistedIdentifiers(const string fpath, const CppLexer.Token[] v) {
  uint result = 0;

  string[string] banned = [
    "strtok" :
      "strtok() is not thread safe, and has safer alternatives.  Consider "
      "folly::split or strtok_r as appropriate.\n"
  ];

  foreach (ref t; v) {
    if (t.type_ != tk!"identifier") continue;
    auto mapIt = t.value_ in banned;
    if (!mapIt) continue;
    lintError(t, *mapIt);
    ++result;
  }

  return result;
}

/**
 * Lint check: no #defined names use an identifier reserved to the
 * implementation.
 *
 * These are enforcing rules that actually apply to all identifiers,
 * but we're only raising warnings for #define'd ones right now.
 */
uint checkDefinedNames(string fpath, Token[] v) {
  // Define a set of exception to rules
  static bool[string] okNames;
  if (okNames.length == 0) {
    static string okNamesInit[] = [
      "__STDC_LIMIT_MACROS",
      "__STDC_FORMAT_MACROS",
      "_GNU_SOURCE",
      "_XOPEN_SOURCE",
    ];

    foreach (i; 0 .. okNamesInit.length) {
      okNames[okNamesInit[i]] = true;
    }
  }

  uint result = 0;
  foreach (i, ref t; v) {
    if (i == 0 || v[i - 1].type_ != tk!"#" || t.type_ != tk!"identifier"
        || t.value != "define") continue;
    const t1 = v[i + 1];
    auto const sym = t1.value_;
    if (t1.type_ != tk!"identifier") {
      // This actually happens because people #define private public
      //   for unittest reasons
      lintWarning(t1, text("you're not supposed to #define ", sym, "\n"));
      continue;
    }
    if (sym.length >= 2 && sym[0] == '_' && isUpper(sym[1])) {
      if (sym in okNames) {
        continue;
      }
      lintWarning(t, text("Symbol ", sym, " invalid."
        "  A symbol may not start with an underscore followed by a "
        "capital letter.\n"));
      ++result;
    } else if (sym.length >= 2 && sym[0] == '_' && sym[1] == '_') {
      if (sym in okNames) {
        continue;
      }
      lintWarning(t, text("Symbol ", sym, " invalid."
        "  A symbol may not begin with two adjacent underscores.\n"));
      ++result;
    } else if (!c_mode /* C is less restrictive about this */ &&
        sym.canFind("__")) {
      if (sym in okNames) {
        continue;
      }
      lintWarning(t, text("Symbol ", sym, " invalid."
        "  A symbol may not contain two adjacent underscores.\n"));
      ++result;
    }
  }
  return result;
}

/**
 * Lint check: only the following forms of catch are allowed:
 *
 * catch (Type &)
 * catch (const Type &)
 * catch (Type const &)
 * catch (Type & e)
 * catch (const Type & e)
 * catch (Type const & e)
 *
 * Type cannot be built-in; this function enforces that it's
 * user-defined.
 */
uint checkCatchByReference(string fpath, Token[] v) {
  uint result = 0;
  foreach (i, ref e; v) {
    if (e.type_ != tk!"catch") continue;
    size_t focal = 1;
    enforce(v[i + focal].type_ == tk!"(", // a "(" comes always after catch
        text(v[i + focal].file_, ":", v[i + focal].line_,
            ": Invalid C++ source code, please compile before lint."));
    ++focal;
    if (v[i + focal].type_ == tk!"...") {
      // catch (...
      continue;
    }
    if (v[i + focal].type_ == tk!"const") {
      // catch (const
      ++focal;
    }
    if (v[i + focal].type_ == tk!"typename") {
      // catch ([const] typename
      ++focal;
    }
    if (v[i + focal].type_ == tk!"::") {
      // catch ([const] [typename] ::
      ++focal;
    }
    // At this position we must have an identifier - the type caught,
    // e.g. FBException, or the first identifier in an elaborate type
    // specifier, such as facebook::FancyException<int, string>.
    if (v[i + focal].type_ != tk!"identifier") {
      const t = v[i + focal];
      lintWarning(t, "Symbol " ~ t.value_ ~ " invalid in "
              "catch clause.  You may only catch user-defined types.\n");
      ++result;
      continue;
    }
    ++focal;
    // We move the focus to the closing paren to detect the "&". We're
    // balancing parens because there are weird corner cases like
    // catch (Ex<(1 + 1)> & e).
    for (size_t parens = 0; ; ++focal) {
      enforce(focal < v.length,
          text(v[i + focal].file_, ":", v[i + focal].line_,
              ": Invalid C++ source code, please compile before lint."));
      if (v[i + focal].type_ == tk!")") {
        if (parens == 0) break;
        --parens;
      } else if (v[i + focal].type_ == tk!"(") {
        ++parens;
      }
    }
    // At this point we're straight on the closing ")". Backing off
    // from there we should find either "& identifier" or "&" meaning
    // anonymous identifier.
    if (v[i + focal - 1].type_ == tk!"&") {
      // check! catch (whatever &)
      continue;
    }
    if (v[i + focal - 1].type_ == tk!"identifier" &&
        v[i + focal - 2].type_ == tk!"&") {
      // check! catch (whatever & ident)
      continue;
    }
    // Oopsies times
    const t = v[i + focal - 1];
    // Get the type string
    string theType;
    foreach (j; 2 .. focal - 1) {
      if (j > 2) theType ~= " ";
      theType ~= v[i + j].value;
    }
    lintError(t, text("Symbol ", t.value_, " of type ", theType,
      " caught by value.  Use catch by (preferably const) reference "
      "throughout.\n"));
    ++result;
  }
  return result;
}

/**
 * Lint check: any usage of throw specifications is a lint error.
 *
 * We track whether we are at either namespace or class scope by
 * looking for class/namespace tokens and tracking nesting level.  Any
 * time we go into a { } block that's not a class or namespace, we
 * disable the lint checks (this is to avoid false positives for throw
 * expressions).
 */
uint checkThrowSpecification(string, Token[] v) {
  uint result = 0;

  // Check for throw specifications inside classes
  result += v.iterateClasses!(
     function uint(Token[] it, Token[] v) {
      uint result = 0;

      it = it.find!(a => a.type_ == tk!"{");
      if (it.empty) {
        return result;
      }

      it.popFront;

      const destructorSequence =
        [tk!"~", tk!"identifier", tk!"(", tk!")",
         tk!"throw", tk!"(", tk!")"];

      for (; !it.empty && it.front.type_ != tk!"\0"; it.popFront) {
        // Skip warnings for empty throw specifications on destructors,
        // because sometimes it is necessary to put a throw() clause on
        // classes deriving from std::exception.
        if (it.atSequence(destructorSequence)) {
          it.popFrontN(destructorSequence.length - 1);
          continue;
        }

        // This avoids warning if the function is named "what", to allow
        // inheriting from std::exception without upsetting lint.
        if (it.front.type_ == tk!"identifier" && it.front.value_ == "what") {
          it.popFront;
          auto sequence = [tk!"(", tk!")", tk!"const",
                           tk!"throw", tk!"(", tk!")"];
          if (it.atSequence(sequence)) {
            it.popFrontN(sequence.length - 1);
          }
          continue;
        }

        if (it.front.type_ == tk!"{") {
          it = skipBlock(it);
          continue;
        }

        if (it.front.type_ == tk!"}") {
          break;
        }

        if (it.front.type_ == tk!"throw" && it[1].type_ == tk!"(") {
          lintWarning(it.front, "Throw specifications on functions are "
              "deprecated.\n");
          ++result;
        }
      }

      return result;
    }
  );

  // Check for throw specifications in functional style code
  for (auto it = v; !it.empty; it.popFront) {
    // Don't accidentally identify a using statement as a namespace
    if (it.front.type_ == tk!"using") {
      if (it[1].type_ == tk!"namespace") {
        it.popFront;
      }
      continue;
    }

    // Skip namespaces, classes, and blocks
    if (it.front.type_.among(tk!"namespace", tk!"class", tk!"struct",
            tk!"union", tk!"{")) {
      auto term = it.find!(x => x.type_ == tk!"{");
      if (term.empty) {
        break;
      }
      it = skipBlock(term);
      continue;
    }

    if (it.front.type_ == tk!"throw" && it[1].type_ == tk!"(") {
      lintWarning(it.front, "Throw specifications on functions are "
        "deprecated.\n");
      ++result;
    }
  }

  return result;
}

/**
 * Lint check: balance of #if(#ifdef, #ifndef)/#endif.
 */
uint checkIfEndifBalance(string fpath, Token[] v) {
  int openIf = 0;

  // Return after the first found error, because otherwise
  // even one missed #if can be cause of a lot of errors.
  foreach (i, ref e; v) {
    if (v[i .. $].atSequence(tk!"#", tk!"if")
        || (v[i .. $].atSequence(tk!"#", tk!"identifier")
            && (v[i + 1].value_ == "ifndef" || v[i + 1].value_ == "ifdef"))) {
      ++openIf;
    } else if (v[i .. $].atSequence(tk!"#", tk!"identifier")
        && v[i + 1].value_ == "endif") {
      --openIf;
      if (openIf < 0) {
        lintError(e, "Unmatched #endif.\n");
        return 1;
      }
    } else if (v[i .. $].atSequence(tk!"#", tk!"else")) {
      if (openIf == 0) {
        lintError(e, "Unmatched #else.\n");
        return 1;
      }
    }
  }

  if (openIf != 0) {
    lintError(v.back, "Unbalanced #if/#endif.\n");
    return 1;
  }

  return 0;
}

/*
 * Lint check: warn about common errors with constructors, such as:
 *  - single-argument constructors that aren't marked as explicit, to avoid them
 *    being used for implicit type conversion (C++ only)
 *  - Non-const copy constructors, or useless const move constructors.
 */
uint checkConstructors(string fpath, Token[] tokensV) {
  if (getFileCategory(fpath) == FileCategory.source_c) {
    return 0;
  }

  uint result = 0;
  string[] nestedClasses;

  const string lintOverride = "/""* implicit *""/";
  const CppLexer.TokenType2[] stdInitializerSequence =
    [tk!"identifier", tk!"::", tk!"identifier", tk!"<"];
  const CppLexer.TokenType2[] voidConstructorSequence =
    [tk!"identifier", tk!"(", tk!"void", tk!")"];

  for (auto tox = tokensV; tox.length; tox.popFront) {
    // Avoid mis-identifying a class context due to use of the "class"
    // keyword inside a template parameter list.
    if (tox.atSequence(tk!"template", tk!"<")) {
      tox = skipTemplateSpec(tox[1 .. $]);
      continue;
    }

    // Parse within namespace blocks, but don't do top-level constructor checks.
    // To do this, we treat namespaces like unnamed classes so any later
    // function name checks will not match against an empty string.
    if (tox.front.type_ == tk!"namespace") {
      tox.popFront;
      for (; tox.front.type_ != tk!"\0"; tox.popFront) {
        if (tox.front.type_ == tk!";") {
          break;
        } else if (tox.front.type_ == tk!"{") {
          nestedClasses ~= "";
          break;
        }
      }
      continue;
    }

    // Extract the class name if a class/struct definition is found
    if (tox.front.type_ == tk!"class" || tox.front.type_ == tk!"struct") {
      tox.popFront;
      // If we hit any C-style structs, we'll handle them like we do namespaces:
      // continue to parse within the block but don't show any lint errors.
      if (tox.front.type_ == tk!"{") {
        nestedClasses ~= "";
      } else if (tox.front.type_ == tk!"identifier") {
        auto classCandidate = tox.front.value_;
        for (; tox.front.type_ != tk!"\0"; tox.popFront) {
          if (tox.front.type_ == tk!";") {
            break;
          } else if (tox.front.type_ == tk!"{") {
            nestedClasses ~= classCandidate;
            break;
          }
        }
      }
      continue;
    }

    // Closing curly braces end the current scope, and should always be balanced
    if (tox.front.type_ == tk!"}") {
      if (nestedClasses.empty) { // parse fail
        return result;
      }
      nestedClasses.popBack;
      continue;
    }

    // Skip unrecognized blocks. We only want to parse top-level class blocks.
    if (tox.front.type_ == tk!"{") {
      tox = skipBlock(tox);
      continue;
    }

    // Only check for constructors if we've previously entered a class block
    if (nestedClasses.empty) {
      continue;
    }

    // Skip past any functions that begin with an "explicit" keyword
    if (tox.front.type_ == tk!"explicit") {
      tox = skipFunctionDeclaration(tox);
      continue;
    }

    // Skip anything that doesn't look like a constructor
    if (!tox.atSequence(tk!"identifier", tk!"(")) {
      continue;
    } else if (tox.front.value_ != nestedClasses.back) {
      tox = skipFunctionDeclaration(tox);
      continue;
    }

    // Suppress error and skip past functions clearly marked as implicit
    if (tox.front.precedingWhitespace_.canFind(lintOverride)) {
      tox = skipFunctionDeclaration(tox);
      continue;
    }

    // Allow zero-argument void constructors
    if (tox.atSequence(voidConstructorSequence)) {
      tox = skipFunctionDeclaration(tox);
      continue;
    }

    Argument[] args;
    auto functionName = Argument(tox[0 .. 1]);
    if (!tox.getFunctionNameAndArguments(functionName, args)) {
      // Parse fail can be due to limitations in skipTemplateSpec, such as with:
      // fn(std::vector<boost::shared_ptr<ProjectionOperator>> children);)
      return result;
    }

    // Allow zero-argument constructors
    if (args.empty) {
      tox = skipFunctionDeclaration(tox);
      continue;
    }

    auto argIt = args[0].tox;
    bool foundConversionCtor = false;
    bool isConstArgument = false;
    if (argIt.front.type_ == tk!"const") {
      isConstArgument = true;
      argIt.popFront;
    }

    // Copy/move constructors may have const (but not type conversion) issues
    // Note: we skip some complicated cases (e.g. template arguments) here
    if (argIt.front.value_ == nestedClasses.back) {
      auto nextType = argIt.length ? argIt[1].type_ : tk!"\0";
      if (nextType != tk!"*") {
        if (nextType == tk!"&" && !isConstArgument) {
          ++result;
          lintError(tox.front, text(
            "Copy constructors should take a const argument: ",
            formatFunction(functionName, args), "\n"
            ));
        } else if (nextType == tk!"&&" && isConstArgument) {
          ++result;
          lintError(tox.front, text(
            "Move constructors should not take a const argument: ",
            formatFunction(functionName, args), "\n"
            ));
        }
        tox = skipFunctionDeclaration(tox);
        continue;
      }
    }

    // Allow std::initializer_list constructors
    if (argIt.atSequence( stdInitializerSequence)
        && argIt.front.value_ == "std"
        && argIt[2].value_ == "initializer_list") {
      tox = skipFunctionDeclaration(tox);
      continue;
    }

    if (args.length == 1) {
      foundConversionCtor = true;
    } else if (args.length >= 2) {
      // 2+ will only be an issue if the trailing arguments have defaults
      for (argIt = args[1].tox; !argIt.empty; argIt.popFront) {
        if (argIt.front.type_ == tk!"=") {
          foundConversionCtor = true;
          break;
        }
      }
    }

    if (foundConversionCtor) {
      ++result;
      lintError(tox.front, text(
        "Single-argument constructor '",
        formatFunction(functionName, args),
        "' may inadvertently be used as a type conversion constructor. Prefix"
        " the function with the 'explicit' keyword to avoid this, or add an /"
        "* implicit *""/ comment to suppress this warning.\n"
        ));
    }

    tox = skipFunctionDeclaration(tox);
  }

  return result;
}

/*
 * Lint check: warn about implicit casts
 *
 * Implicit casts not marked as explicit can be dangerous if not used carefully
 */
uint checkImplicitCast(string fpath, Token[] tokensV) {
  if (c_mode || getFileCategory(fpath) == FileCategory.source_c) {
    return 0;
  }

  uint result = 0;

  const string lintOverride = "/""* implicit *""/";

  for (auto tox = tokensV; !tox.empty; tox.popFront) {
    // Skip past any functions that begin with an "explicit" keyword
    if (tox.atSequence(tk!"explicit", tk!"constexpr", tk!"operator")) {
      tox.popFrontN(2);
      continue;
    }
    if (tox.atSequence(tk!"explicit", tk!"operator") ||
        tox.atSequence(tk!"::", tk!"operator")) {
      tox.popFront;
      continue;
    }

    // Special case operator bool(), we don't want to allow over-riding
    if (tox.atSequence(tk!"operator", tk!"bool", tk!"(", tk!")")) {
      if (tox[4 .. $].atSequence(tk!"=", tk!"delete") ||
          tox[4 .. $].atSequence(tk!"const", tk!"=", tk!"delete")) {
        // Deleted implicit operators are ok.
        continue;
      }

      ++result;
      lintError(tox.front, "operator bool() is dangerous. "
        "In C++11 use explicit conversion (explicit operator bool()), "
        "otherwise use something like the safe-bool idiom if the syntactic "
        "convenience is justified in this case, or consider defining a "
        "function (see http://www.artima.com/cppsource/safebool.html for more "
        "details).\n"
      );
      continue;
    }

    // Only want to process operators which do not have the overide
    if (tox.front.type_ != tk!"operator" ||
        tox.front.precedingWhitespace_.canFind(lintOverride)) {
      continue;
    }

    // Assume it is an implicit conversion unless proven otherwise
    bool isImplicitConversion = false;
    string typeString;
    for (auto typeIt = tox[1 .. $]; !typeIt.empty; typeIt.popFront) {
      if (typeIt.front.type_ == tk!"(") {
        break;
      }

      switch (typeIt.front.type_.id) {
      case tk!"double".id:
      case tk!"float".id:
      case tk!"int".id:
      case tk!"short".id:
      case tk!"unsigned".id:
      case tk!"long".id:
      case tk!"signed".id:
      case tk!"void".id:
      case tk!"bool".id:
      case tk!"wchar_t".id:
      case tk!"char".id:
      case tk!"identifier".id: isImplicitConversion = true; break;
      default:            break;
      }

      if (!typeString.empty()) {
        typeString ~= ' ';
      }
      typeString ~= typeIt.front.value;
    }

    // The operator my not have been an implicit conversion
    if (!isImplicitConversion) {
      continue;
    }

    ++result;
    lintWarning(tox.front, text(
      "Implicit conversion to '",
      typeString,
      "' may inadvertently be used. Prefix the function with the 'explicit'"
      " keyword to avoid this, or add an /* implicit *""/ comment to"
      " suppress this warning.\n"
      ));
  }

  return result;
}

enum AccessRestriction {
  PRIVATE,
  PUBLIC,
  PROTECTED
}

struct ClassParseState {
  string name_;
  AccessRestriction access_;
  Token token_;
  bool has_virt_function_;
  bool ignore_ = true;

  this(string n, AccessRestriction a, Token t) {
    name_ = n;
    access_ = a;
    token_ = t;
    ignore_ = false;
  }
}

/**
 * Lint check: warn about non-virtual destructors in base classes
 */
uint checkVirtualDestructors(string fpath, Token[] v) {
  if (getFileCategory(fpath) == FileCategory.source_c) {
    return 0;
  }

  uint result = 0;
  ClassParseState[] nestedClasses;

  for (auto it = v; !it.empty; it.popFront) {
    // Avoid mis-identifying a class context due to use of the "class"
    // keyword inside a template parameter list.
    if (it.atSequence(tk!"template", tk!"<")) {
      it.popFront;
      it = skipTemplateSpec(it);
      continue;
    }

    // Treat namespaces like unnamed classes
    if (it.front.type_ == tk!"namespace") {
      it.popFront;
      for (; it.front.type_ != tk!"\0"; it.popFront) {
        if (it.front.type_ == tk!";") {
          break;
        } else if (it.front.type_ == tk!"{") {
          nestedClasses ~= ClassParseState();
          break;
        }
      }
      continue;
    }

    if (it.front.type_ == tk!"class" || it.front.type_ == tk!"struct") {
      auto access = it.front.type_ == tk!"class" ?
          AccessRestriction.PRIVATE : AccessRestriction.PUBLIC;
      auto token = it.front;
      it.popFront;

      // If we hit any C-style structs or non-base classes,
      // we'll handle them like we do namespaces:
      // continue to parse within the block but don't show any lint errors.
      if(it.front.type_ == tk!"{") {
        nestedClasses ~= ClassParseState();
      } else if (it.front.type_ == tk!"identifier") {
        auto classCandidate = it.front.value_;

        for (; it.front.type_ != tk!"\0"; it.popFront) {
          if (it.front.type_ == tk!":") {
            // Skip to the class block if we have a derived class
            for (; it.front.type_ != tk!"\0"; it.popFront) {
              if (it.front.type_ == tk!"{") { // full declaration
                break;
              }
            }
            // Ignore non-base classes
            nestedClasses ~= ClassParseState();
            break;
          } else if (it.front.type_ == tk!"identifier") {
            classCandidate = it.front.value_;
          } else if (it.front.type_ == tk!"{") {
            nestedClasses ~=
              ClassParseState(classCandidate, access, token);
            break;
          }
        }
      }
      continue;
    }

    // Skip unrecognized blocks. We only want to parse top-level class blocks.
    if (it.front.type_ == tk!"{") {
      it = skipBlock(it);
      continue;
    }

    // Only check for virtual methods if we've previously entered a class block
    if (nestedClasses.empty) {
      continue;
    }

    auto c = &(nestedClasses.back);

    // Closing curly braces end the current scope, and should always be balanced
    if (it.front.type_ == tk!"}") {
      if (nestedClasses.empty) { // parse fail
        return result;
      }
      if (!c.ignore_ && c.has_virt_function_) {
        ++result;
        lintWarning(c.token_, text("Base class ", c.name_,
          " has virtual functions but a public non-virtual destructor.\n"));
      }
      nestedClasses.popBack;
      continue;
    }

    // Virtual function
    if (it.front.type_ == tk!"virtual") {
      if (it[1].type_ == tk!"~") {
        // Has virtual destructor
        c.ignore_ = true;
        it = skipFunctionDeclaration(it);
        continue;
      }
      c.has_virt_function_ = true;
      it = skipFunctionDeclaration(it);
      continue;
    }

    // Non-virtual destructor
    if (it.atSequence(tk!"~", tk!"identifier")) {
      if (c.access_ != AccessRestriction.PUBLIC) {
        c.ignore_ = true;
      }
      it = skipFunctionDeclaration(it);
      continue;
    }

    if (it.front.type_ == tk!"public") {
      c.access_ = AccessRestriction.PUBLIC;
    } else if (it.front.type_ == tk!"protected") {
      c.access_ = AccessRestriction.PROTECTED;
    } else if (it.front.type_ == tk!"private") {
      c.access_ = AccessRestriction.PRIVATE;
    }
  }
  return result;
}

/**
 * Lint check: if header file contains include guard.
 */
uint checkIncludeGuard(string fpath, Token[] v) {
  if (getFileCategory(fpath) != FileCategory.header) {
    return 0;
  }

  // Allow #pragma once
  if (v.atSequence(tk!"#", tk!"identifier", tk!"identifier")
      && v[1].value_ == "pragma" && v[2].value_ == "once") {
    return 0;
  }

  // Looking for the include guard:
  //   #ifndef [name]
  //   #define [name]
  if (!v.atSequence(tk!"#", tk!"identifier", tk!"identifier",
          tk!"#", tk!"identifier", tk!"identifier")
      || v[1].value_ != "ifndef" || v[4].value_ != "define") {
    // There is no include guard in this file.
    lintError(v.front(), "Missing include guard.\n");
    return 1;
  }

  uint result = 0;

  // Check if there is a typo in guard name.
  if (v[2].value_ != v[5].value_) {
    lintError(v[3], text("Include guard name mismatch; expected ",
      v[2].value_, ", saw ", v[5].value_, ".\n"));
    ++result;
  }

  int openIf = 0;
  for (size_t i = 0; i != v.length; ++i) {
    if (v[i].type_ == tk!"\0") break;

    // Check if we have something after the guard block.
    if (openIf == 0 && i != 0) {
      lintError(v[i], "Include guard doesn't cover the entire file.\n");
      ++result;
      break;
    }

    if (v[i .. $].atSequence(tk!"#", tk!"if")
        || (v[i .. $].atSequence(tk!"#", tk!"identifier")
            && v[i + 1].value_.among("ifndef", "ifdef"))) {
      ++openIf;
    } else if (v[i .. $].atSequence(tk!"#", tk!"identifier")
        && v[i + 1].value_ == "endif") {
      ++i; // hop over the else
      --openIf;
    }
  }

  return result;
}

uint among(T, U...)(auto ref T t, auto ref U options) if (U.length >= 1) {
  foreach (i, unused; U) {
    if (t == options[i]) return i + 1;
  }
  return 0;
}

/**
 * Lint check: inside a header file, namespace facebook must be introduced
 * at top level only, using namespace directives are not allowed, unless
 * they are scoped to an inline function or function template.
 */
uint checkUsingDirectives(string fpath, Token[] v) {
  if (!isHeader(fpath)) {
    // This check only looks at headers. Inside .cpp files, knock
    // yourself out.
    return 0;
  }
  uint result = 0;
  uint openBraces = 0;
  uint openNamespaces = 0;

  for (auto i = v; !i.empty; i.popFront) {
    if (i.front.type_ == tk!"{") {
      ++openBraces;
      continue;
    }
    if (i.front.type_ == tk!"}") {
      if (openBraces == 0) {
        // Closed more braces than we had.  Syntax error.
        return 0;
      }
      if (openBraces == openNamespaces) {
        // This brace closes namespace.
        --openNamespaces;
      }
      --openBraces;
      continue;
    }
    if (i.front.type_ == tk!"namespace") {
      // Namespace alias doesn't open a scope.
      if (i[1 .. $].atSequence(tk!"identifier", tk!"=")) {
        continue;
      }

      // If we have more open braces than namespace, someone is trying
      // to nest namespaces inside of functions or classes here
      // (invalid C++), so we have an invalid parse and should give
      // up.
      if (openBraces != openNamespaces) {
        return result;
      }

      // Introducing an actual namespace.
      if (i[1].type_ == tk!"{") {
        // Anonymous namespace, let it be. Next iteration will hit the '{'.
        ++openNamespaces;
        continue;
      }

      i.popFront;
      if (i.front.type_ != tk!"identifier") {
        // Parse error or something.  Give up on everything.
        return result;
      }
      if (i.front.value_ == "facebook" && i[1].type_ == tk!"{") {
        // Entering facebook namespace
        if (openBraces > 0) {
          lintError(i.front, "Namespace facebook must be introduced "
            "at top level only.\n");
          ++result;
        }
      }
      if (i[1].type_ != tk!"{" && i[1].type_ != tk!"::") {
        // Invalid parse for us.
        return result;
      }
      ++openNamespaces;
      // Continue analyzing, next iteration will hit the '{' or the '::'
      continue;
    }
    if (i.front.type_ == tk!"using") {
      // We're on a "using" keyword
      i.popFront;
      if (i.front.type_ != tk!"namespace") {
        // we only care about "using namespace"
        continue;
      }
      if (openBraces == 0) {
        lintError(i.front, "Using directive not allowed at top level"
          " or inside namespace facebook.\n");
        ++result;
      } else if (openBraces == openNamespaces) {
        // We are directly inside the namespace.
        lintError(i.front, "Using directive not allowed in header file, "
          "unless it is scoped to an inline function or function template.\n");
        ++result;
      }
    }
  }
  return result;
}

/**
 * Lint check: don't allow certain "using namespace" directives to occur
 * together, e.g. if "using namespace std;" and "using namespace boost;"
 * occur, we should warn because names like "shared_ptr" are ambiguous and
 * could refer to either "std::shared_ptr" or "boost::shared_ptr".
 */
uint checkUsingNamespaceDirectives(string fpath, Token[] v) {
  bool[string][] MUTUALLY_EXCLUSIVE_NAMESPACES = [
    [ "std":1, "std::tr1":1, "boost":1, "::std":1, "::std::tr1":1, "::boost":1 ],
    // { "list", "of", "namespaces", "that", "should::not::appear", "together" }
  ];

  uint result = 0;
  // (namespace => line number) for all visible namespaces
  // we can probably simplify the implementation by getting rid of this and
  // performing a "nested scope lookup" by looking up symbols in the current
  // scope, then the enclosing scope etc.
  size_t[string] allNamespaces;
  bool[string][] nestedNamespaces;
  int[] namespaceGroupCounts = new int[MUTUALLY_EXCLUSIVE_NAMESPACES.length];

  ++nestedNamespaces.length;
  assert(!nestedNamespaces.back.length);
  for (auto i = v; !i.empty; i.popFront) {
    if (i.front.type_ == tk!"{") {
      // create a new set for all namespaces in this scope
      ++nestedNamespaces.length;
    } else if (i.front.type_ == tk!"}") {
      if (nestedNamespaces.length == 1) {
        // closed more braces than we had.  Syntax error.
        return 0;
      }
      // delete all namespaces that fell out of scope
      foreach (iNs, unused; nestedNamespaces.back) {
        allNamespaces.remove(iNs);
        foreach (ii, iGroup; MUTUALLY_EXCLUSIVE_NAMESPACES) {
          if (iNs in iGroup) {
            --namespaceGroupCounts[ii];
          }
        }
      }
      nestedNamespaces.popBack;
    } else if (i.atSequence(tk!"using", tk!"namespace")) {
      i.popFrontN(2);
      // crude method for getting the namespace name; this assumes the
      // programmer puts a semicolon at the end of the line and doesn't do
      // anything else invalid
      string ns;
      while (i.front.type_ != tk!";") {
        ns ~= i.front.value;
        i.popFront;
      }
      auto there = ns in allNamespaces;
      if (there) {
        // duplicate using namespace directive
        size_t line = *there;
        string error = format("Duplicate using directive for "
            "namespace \"%s\" (line %s).\n", ns, line);
        lintError(i.front, error);
        ++result;
        continue;
      } else {
        allNamespaces[ns] = i.front.line_;
      }
      nestedNamespaces.back[ns] = true;
      // check every namespace group for this namespace
      foreach (ii, ref iGroup; MUTUALLY_EXCLUSIVE_NAMESPACES) {
        if (ns !in iGroup) {
          continue;
        }
        if (namespaceGroupCounts[ii] >= 1) {
          // mutual exclusivity violated
          // find the first conflicting namespace in the file
          string conflict;
          size_t conflictLine = size_t.max;
          foreach (iNs, unused; iGroup) {
            if (iNs == ns) {
              continue;
            }
            auto it = iNs in allNamespaces;
            if (it && *it < conflictLine) {
              conflict = iNs;
              conflictLine = *it;
            }
          }
          string error = format("Using namespace conflict: \"%s\" "
              "and \"%s\" (line %s).\n",
              ns, conflict, conflictLine);
          lintError(i.front, error);
          ++result;
        }
        ++namespaceGroupCounts[ii];
      }
    }
  }

  return result;
}

/**
 * Lint check: don't allow heap allocated exception, i.e. throw new Class()
 *
 * A simple check for two consecutive tokens "throw new"
 *
 */
uint checkThrowsHeapException(string fpath, Token[] v) {
  uint result = 0;
  for (; !v.empty; v.popFront) {
    if (v.atSequence(tk!"throw", tk!"new")) {
      size_t focal = 2;
      string msg;

      if (v[focal].type_ == tk!"identifier") {
        msg = text("Heap-allocated exception: throw new ", v[focal].value_,
            "();");
      } else if (v[focal .. $].atSequence(tk!"(", tk!"identifier", tk!")")) {
        // Alternate syntax throw new (Class)()
        ++focal;
        msg = text("Heap-allocated exception: throw new (",
                       v[focal].value_, ")();");
      } else {
        // Some other usage of throw new Class().
        msg = "Heap-allocated exception: throw new was used.";
      }
      lintError(v[focal], text(msg, "\n  This is usually a mistake in C++. "
        "Please refer to the C++ Primer (https://www.intern.facebook.com/"
        "intern/wiki/images/b/b2/C%2B%2B--C%2B%2B_Primer.pdf) for FB exception "
        "guidelines.\n"));
      ++result;
    }
  }
  return result;
}

/**
 * Lint check: if source has explicit references to HPHP namespace, ensure
 * there is at least a call to f_require_module('file') for some file.
 *
 *  {
 *  }
 *
 *  using namespace HPHP;
 *  using namespace ::HPHP;
 *
 *  [using] HPHP::c_className
 *  [using] ::HPHP::c_className
 *  HPHP::f_someFunction();
 *  HPHP::c_className.mf_memberFunc();
 *  ::HPHP::f_someFunction();
 *  ::HPHP::c_className.mf_memberFunc();
 *
 *  Also, once namespace is opened, it can be used bare, so we have to
 *  blacklist known HPHP class and function exports f_XXXX and c_XXXX.  It
 *  should be noted that function and class references are not the only
 *  potentially dangerous references, however they are by far the most common.
 *  A few FXL functions use constants as well.  Unfortunately, the HPHP
 *  prefixes are particularly weak and may clash with common variable
 *  names, so we try to be as careful as possible to make sure the full
 *  scope on all identifiers is resolved.  Specifically excluded are
 *
 *  c_str (outside using namespace declaration)
 *  ::f_0
 *  OtherScope::f_func
 *  ::OtherScope::c_class
 *  somecomplex::nameorclass::reference
 *
 */
uint checkHPHPNamespace(string fpath, Token[] v) {
  uint result = 0;
  uint openBraces = 0;
  uint useBraceLevel = 0;
  bool usingHPHPNamespace = false;
  bool gotRequireModule = false;
  static const blacklist =
    ["c_", "f_", "k_", "ft_"];
  bool isSigmaFXLCode = false;
  Token sigmaCode;
  for (auto i = v; !i.empty; i.popFront) {
    auto s = toLower(i.front.value);
    bool boundGlobal = false;

    // Track nesting level to determine when HPHP namespace opens / closes
    if (i.front.type_ == tk!"{") {
      ++openBraces;
      continue;
    }
    if (i.front.type_ == tk!"}") {
      if (openBraces) {
        --openBraces;
      }
      if (openBraces < useBraceLevel) {
        usingHPHPNamespace = false;
        gotRequireModule = false;
      }
      continue;
    }

    // Find using namespace declarations
    if (i.atSequence(tk!"using", tk!"namespace")) {
      i.popFrontN(2);
      if (i.front.type_ == tk!"::") {
        // optional syntax
        i.popFront;
      }
      if (i.front.type_ != tk!"identifier") {
        lintError(i.front, text("Symbol ", i.front.value_,
                " not valid in using namespace declaration.\n"));
        ++result;
        continue;
      }
      if (i.front.value == "HPHP" && !usingHPHPNamespace) {
        usingHPHPNamespace = true;
        useBraceLevel = openBraces;
        continue;
      }
    }

    // Find identifiers, but make sure we start from top level name scope
    if (i.atSequence(tk!"::", tk!"identifier")) {
      i.popFront;
      boundGlobal = true;
    }
    if (i.front.type_ == tk!"identifier") {
      bool inHPHPScope = usingHPHPNamespace && !boundGlobal;
      bool boundHPHP = false;
      if (i[1 .. $].atSequence(tk!"::", tk!"identifier")) {
        if (i.front.value == "HPHP") {
          inHPHPScope = true;
          boundHPHP = true;
          i.popFrontN(2);
        }
      }
      if (inHPHPScope) {
        if (i.front.value_ == "f_require_module") {
          gotRequireModule = true;
        }
        // exempt std::string.c_str
        if (!gotRequireModule && !(i.front.value_ == "c_str" && !boundHPHP)) {
          foreach (l; blacklist) {
            if (i.front.value.length > l.length) {
              auto substr = i.front.value[0 .. l.length];
              if (substr == l) {
                lintError(i.front, text("Missing f_require_module before "
                  "suspected HPHP namespace reference ", i.front.value_, "\n"));
                ++result;
              }
            }
          }
        }
      }
      // strip remaining sub-scoped tokens
      while (i.atSequence(tk!"identifier", tk!"::")) {
        i.popFrontN(2);
      }
    }
  }
  return result;
}


/**
 * Lint checks:
 * 1) Warn if any file includes a deprecated include.
 * 2) Warns about include certain "expensive" headers in other headers
 */
uint checkQuestionableIncludes(string fpath, Token[] v) {
  // Set storing the deprecated includes. Add new headers here if you'd like
  // to deprecate them
  const bool[string] deprecatedIncludes = [
    "common/base/Base.h":1,
    "common/base/StringUtil.h":1,
  ];

  // Set storing the expensive includes. Add new headers here if you'd like
  // to mark them as expensive
  const bool[string] expensiveIncludes = [
    "multifeed/aggregator/gen-cpp/aggregator_types.h":1,
    "multifeed/shared/gen-cpp/multifeed_types.h":1,
    "admarket/adfinder/if/gen-cpp/adfinder_types.h":1,
  ];

  bool includingFileIsHeader = (getFileCategory(fpath) == FileCategory.header);
  uint result = 0;
  for (; !v.empty; v.popFront) {
    if (!v.atSequence(tk!"#", tk!"identifier") || v[1].value != "include") {
      continue;
    }
    if (v[2].type_ != tk!"string_literal" || v[2].value == "PRECOMPILED") {
      continue;
    }

    string includedFile = getIncludedPath(v[2].value);

    if (includedFile in deprecatedIncludes) {
      lintWarning(v.front, text("Including deprecated header ",
              includedFile, "\n"));
      ++result;
    }
    if (includingFileIsHeader && includedFile in expensiveIncludes) {
      lintWarning(v.front,
                  text("Including expensive header ",
                       includedFile, " in another header, prefer to forward ",
                       "declare symbols instead if possible\n"));
      ++result;
    }
  }
  return result;
}

/**
 * Lint check: Ensures .cpp files include their associated header first
 * (this catches #include-time dependency bugs where .h files don't
 * include things they depend on)
 */
uint checkIncludeAssociatedHeader(string fpath, Token[] v) {
  if (!isSource(fpath)) {
    return 0;
  }

  auto fileName = fpath.baseName;
  auto fileNameBase = getFileNameBase(fileName);
  auto parentPath = fpath.absolutePath.dirName.buildNormalizedPath;
  uint totalIncludesFound = 0;

  for (; !v.empty; v.popFront) {
    if (!v.atSequence(tk!"#", tk!"identifier") || v[1].value != "include") {
      continue;
    }
    if (v[2].value == "PRECOMPILED") continue;
    ++totalIncludesFound;
    if (v[2].type_ != tk!"string_literal") continue;

    string includedFile = getIncludedPath(v[2].value).baseName;
    string includedParentPath =
      getIncludedPath(v[2].value_).dirName;
    if (includedParentPath == ".") includedParentPath = null;

    if (getFileNameBase(includedFile) == fileNameBase &&
        (includedParentPath.empty ||
         parentPath.endsWith('/' ~ includedParentPath))) {
      if (totalIncludesFound > 1) {
        lintError(v.front, text("The associated header file of .cpp files "
                "should be included before any other includes.\n(This "
                "helps catch missing header file dependencies in the .h)\n"));
        return 1;
      }
      return 0;
    }
  }
  return 0;
}

/**
 * Lint check: if encounter memset(foo, sizeof(foo), 0), we warn that the order
 * of the arguments is wrong.
 * Known unsupported case: calling memset inside another memset. The inner
 * call will not be checked.
 */
uint checkMemset(string fpath, Token[] v) {
  uint result = 0;

  for (; !v.empty; v.popFront) {
    if (!v.atSequence(tk!"identifier", tk!"(") || v.front.value_ != "memset") {
      continue;
    }
    Argument[] args;
    Argument functionName;
    if (!getFunctionNameAndArguments(v, functionName, args)) {
      return result;
    }

    // If there are more than 3 arguments, then there might be something wrong
    // with skipTemplateSpec but the iterator didn't reach the EOF (because of
    // a '>' somewhere later in the code). So we only deal with the case where
    // the number of arguments is correct.
    if (args.length == 3) {
      // wrong calls include memset(..., ..., 0) and memset(..., sizeof..., 1)
      bool error =
        (args[2].tox.length == 1) &&
        (
          (args[2].first.value_ == "0") ||
          (args[2].first.value_ == "1" && args[1].first.type_ == tk!"sizeof")
        );
      if (!error) {
        continue;
      }
      swap(args[1], args[2]);
      lintError(functionName.first,
        "Did you mean " ~ formatFunction(functionName, args) ~ "?\n");
      result++;
    }
  }
  return result;
}

uint checkInlHeaderInclusions(string fpath, Token[] v) {
  uint result = 0;

  auto fileName = fpath.baseName;
  auto fileNameBase = getFileNameBase(fileName);

  for (; !v.empty; v.popFront) {
    if (!v.atSequence(tk!"#", tk!"identifier", tk!"string_literal")
        || v[1].value_ != "include") {
      continue;
    }
    v.popFrontN(2);

    auto includedPath = getIncludedPath(v.front.value_);
    if (getFileCategory(includedPath) != FileCategory.inl_header) {
      continue;
    }

    if (includedPath.baseName.getFileNameBase == fileNameBase) {
      continue;
    }

    lintError(v.front, text("A -inl file (", includedPath, ") was "
      "included even though this is not its associated header.  "
      "Usually files like Foo-inl.h are implementation details and should "
      "not be included outside of Foo.h.\n"));
    ++result;
  }

  return result;
}

uint checkFollyDetail(string fpath, Token[] v) {
  if (fpath.canFind("folly")) return 0;

  uint result = 0;
  for (; !v.empty; v.popFront) {
    if (!v.atSequence(tk!"identifier", tk!"::", tk!"identifier", tk!"::")) {
      continue;
    }
    if (v.front.value_ == "folly" && v[2].value_ == "detail") {
      lintError(v.front, text("Code from folly::detail is logically "
                              "private, please avoid use outside of "
                              "folly.\n"));
      ++result;
    }
  }

  return result;
}

uint checkFollyStringPieceByValue(string fpath, Token[] v) {
  uint result = 0;
  for (; !v.empty; v.popFront) {
    if ((v.atSequence(tk!"const", tk!"identifier", tk!"&") &&
         v[1].value_ == "StringPiece") ||
        (v.atSequence(tk!"const", tk!"identifier", tk!"::",
                      tk!"identifier", tk!"&") &&
         v[1].value_ == "folly" &&
         v[3].value_ == "StringPiece")) {
      lintWarning(v.front, text("Pass folly::StringPiece by value "
                                "instead of as a const reference.\n"));
      ++result;
    }
  }

  return result;
}

/**
 * Lint check: classes should not have protected inheritance.
 */
uint checkProtectedInheritance(string fpath, Token[] v) {

  uint result = v.iterateClasses!(
    (Token[] it, Token[] v) {
      uint result = 0;
      auto term = it.find!((t) => t.type_.among(tk!":", tk!"{"));

      if (term.empty) {
        return result;
      }

      for (; it.front.type_ != tk!"\0"; it.popFront) {
        if (it.front.type_ == tk!"{") {
          break;
        }

        // Detect a member access specifier.
        if (it.atSequence(tk!"protected", tk!"identifier")) {
          lintWarning(it.front, "Protected inheritance is sometimes not a good "
              "idea. Read http://stackoverflow.com/questions/"
              "6484306/effective-c-discouraging-protected-inheritance "
              "for more information.\n");
          ++result;
        }
      }

      return result;
    }
  );

  return result;
}

uint checkUpcaseNull(string fpath, Token[] v) {
  uint ret = 0;
  foreach (ref t; v) {
    if (t.type_ == tk!"identifier" && t.value_ == "NULL") {
      lintAdvice(t,
        "Prefer `nullptr' to `NULL' in new C++ code.  Unlike `NULL', "
        "`nullptr' can't accidentally be used in arithmetic or as an "
        "integer. See "
        "http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2007/n2431.pdf"
        " for details.\n");
      ++ret;
    }
  }
  return ret;
}

static bool endsClass(CppLexer.TokenType2 tkt) {
  return tkt.among(tk!"\0", tk!"{", tk!";") != 0;
}

static bool isAccessSpecifier(CppLexer.TokenType2 tkt) {
  return tkt.among(tk!"private", tk!"public", tk!"protected") != 0;
}

static bool checkExceptionAndSkip(ref Token[] it) {
  if (it.atSequence(tk!"identifier", tk!"::")) {
    if (it.front.value_ != "std") {
      it.popFrontN(2);
      return false;
    }
    it.popFrontN(2);
  }

  return it.front.type_ == tk!"identifier" && it.front.value_ == "exception";
}

static bool badExceptionInheritance(TokenType classType, TokenType access) {
  return (classType == tk!"class" && access != tk!"public") ||
    (classType == tk!"struct" && access == tk!"private");
}

/**
 * Check for non-public std::exception inheritance.
 *
 * Enforces the following:
 *  1. "class foo: <access-spec> std::inheritance"
 *    is bad if "<access-spec>" is not "public"
 *  2. struct foo: <access-spec> std::inheritance"
 *    is bad if "<access-spec>" is "private"
 *  Handles multiple inheritance.
 *
 *  Assumptions:
 *  1. If "exception" is not prefixed with a
 *  namespace, it is in the "std" namespace.
 */
uint checkExceptionInheritance(string fpath, Token[] v) {
  uint result = v.iterateClasses!(
    (Token[] it, Token[] v) {
      auto classType = it.front.type_; // struct, union or class

      if (classType == tk!"union") return 0;

      while (!endsClass(it.front.type_) && it.front.type_ != tk!":") {
        it.popFront;
      }
      if (it.front.type_ != tk!":") {
        return 0;
      }

      it.popFront;

      auto access = tk!"protected"; // not really, just a safe initializer
      bool warn = false;
      while (!endsClass(it.front.type_)) {
        if (isAccessSpecifier(it.front.type_)) {
          access = it.front.type_;
        } else if (it.front.type_ == tk!",") {
          access = tk!"protected"; // reset
        } else if (checkExceptionAndSkip(it)) {
          warn = badExceptionInheritance(classType, access);
        }
        if (warn) {
          lintWarning(it.front, "std::exception should not be inherited "
            "non-publicly, as this base class will not be accessible in "
            "try..catch(const std::exception& e) outside the derived class. "
            "See C++ standard section 11.2 [class.access.base] / 4.\n");
          return 1;
        }
        it.popFront;
      }

      return 0;
    }
  );

  return result;
}

/**
 * Lint check: Identifies incorrect usage of unique_ptr() with arrays. In other
 * words the unique_ptr is used with an array allocation, but not declared as
 * an array. The canonical example is: unique_ptr<Foo> Bar(new Foo[8]), which
 * compiles fine but should be unique_ptr<Foo[]> Bar(new Foo[8]).
 */
uint checkUniquePtrUsage(string fpath, Token[] v) {
  uint result = 0;

  for (auto iter = v; !iter.empty; iter.popFront) {
    const ident = readQualifiedIdentifier(iter);
    bool ofInterest =
      (ident.length == 1 && ident[0] == "unique_ptr") ||
      (ident.length == 2 && ident[0] == "std" && ident[1] == "unique_ptr");
    if (!ofInterest) continue;

    // Keep the outer loop separate from the lookahead from here out.
    // We want this after the detection of {std::}?unique_ptr above or
    // we'd give errors on qualified unique_ptr's twice.
    auto i = iter;

    // Save the unique_ptr iterator because we'll raise any warnings
    // on that line.
    const uniquePtrIt = i;

    // Determine if the template parameter is an array type.
    if (i.front.type_ != tk!"<") continue;
    bool uniquePtrHasArray = false;
    i = skipTemplateSpec(i, &uniquePtrHasArray);
    if (i.front.type_ == tk!"\0") {
      return result;
    }
    assert(i.front.type_ == tk!">");
    i.popFront;

    /*
     * We should see an optional identifier, then an open paren, or
     * something is weird so bail instead of giving false positives.
     *
     * Note that we could be looking at a function declaration and its
     * return type right now---we're assuming we won't see a
     * new-expression in the argument declarations.
     */
    if (i.front.type_ == tk!"identifier") i.popFront;
    if (i.front.type_ != tk!"(") continue;
    i.popFront;

    uint parenNest = 1;
    for (; i.front.type_ != tk!"\0"; i.popFront) {
      if (i.front.type_ == tk!"(") {
        ++parenNest;
        continue;
      }

      if (i.front.type_ == tk!")") {
        if (--parenNest == 0) break;
        continue;
      }

      if (i.front.type_ != tk!"new" || parenNest != 1) continue;
      i.popFront;

      // We're looking at the new expression we care about.  Try to
      // ensure it has array brackets only if the unique_ptr type did.
      while (i.front.type_ == tk!"identifier" || i.front.type_ == tk!"::") {
        i.popFront;
      }
      if (i.front.type_ == tk!"<") {
        i = skipTemplateSpec(i);
        if (i.front.type_ == tk!"\0") return result;
        i.popFront;
      } else {
        while (atBuiltinType(i)) i.popFront;
      }
      while (i.front.type_.among(tk!"*", tk!"const", tk!"volatile")) {
        i.popFront;
      }

      bool newHasArray = i.front.type_ == tk!"[";
      if (newHasArray != uniquePtrHasArray) {
        lintError(uniquePtrIt.front,
          uniquePtrHasArray
            ? text("unique_ptr<T[]> should be used with an array type\n")
            : text("unique_ptr<T> should be unique_ptr<T[]> when "
                       "used with an array\n")
        );
        ++result;
      }
      break;
    }
  }

  return result;
}

/**
 * Lint check: Identifies usage of shared_ptr() and suggests replacing with
 * make_shared(). When shared_ptr takes 3 arguments a custom allocator is used
 * and allocate_shared() is suggested.
 * The suggested replacements perform less memory allocations.
 *
 * Overall, matches usages of <namespace>::shared_ptr<T> id(new Ctor(),...);
 * where <namespace> is one of "std", "boost" or "facebook". It also matches
 * unqualified usages.
 * Requires the first argument of the call to be a "new expression" starting
 * with the "new" keyword.
 * That is not inclusive of all usages of that construct but it allows
 * to easily distinguish function calls vs. function declarations.
 * Essentially this function matches the following
 * <namespace>::shared_ptr TemplateSpc identifier Arguments
 * where the first argument starts with "new" and <namespace> is optional
 * and, when present, one of the values described above.
 */
uint checkSmartPtrUsage(string fpath, Token[] v) {
  uint result = 0;

  for (auto i = v; !i.empty; i.popFront) {
    // look for unqualified 'shared_ptr<' or 'namespace::shared_ptr<' where
    // namespace is one of 'std', 'boost' or 'facebook'
    if (i.front.type_ != tk!"identifier") continue;
    const startLine = i;
    const ns = i.front.value;
    if (i[1].type_ == tk!"::") {
      i.popFrontN(2);
      if (!i.atSequence(tk!"identifier", tk!"<")) continue;
    } else if (i[1].type_ != tk!"<") {
      continue;
    }
    const fn = i.front.value;
    // check that we have the functions and namespaces we care about
    if (fn != "shared_ptr") continue;
    if (fn != ns && ns != "std" && ns != "boost" && ns != "facebook") {
      continue;
    }

    // skip over the template specification
    i.popFront;
    i = skipTemplateSpec(i);
    if (i.front.type_ == tk!"\0") {
      return result;
    }
    i.popFront;
    // look for a possible function call
    if (!i.atSequence(tk!"identifier", tk!"(")) continue;

    i.popFront;
    Argument[] args;
    // ensure the function call first argument is a new expression
    if (!getRealArguments(i, args)) continue;

    if (i.front.type_ == tk!")" && i[1].type_ == tk!";"
        && args.length > 0 && args[0].first.type_ == tk!"new") {
      // identifies what to suggest:
      // shared_ptr should be  make_shared unless there are 3 args in which
      // case an allocator is used and thus suggests allocate_shared.
      string newFn = args.length == 3 ? "allocate_shared" :  "make_shared";
      string qFn = ns;
      string qNewFn = newFn;
      if (ns != fn) {
        qFn ~= "::" ~ fn;
        // qNewFn.insert(0, "::").insert(0, ns.str());
        qNewFn = ns ~ "::" ~ qNewFn;
      }
      lintWarning(startLine.front,
          text(qFn, " should be replaced by ", qNewFn, ". ", newFn,
          " performs better with less allocations. Consider changing '", qFn,
          "<Foo> p(new Foo(w));' with 'auto p = ", qNewFn, "<Foo>(w);'\n"));
      ++result;
    }
  }

  return result;
}

/*
 * Lint check: some identifiers are warned on because there are better
 * alternatives to whatever they are.
 */
uint checkBannedIdentifiers(string fpath, Token[] v) {
  uint result = 0;

  // Map from identifier to the rationale.
  string[string] warnings = [
    // https://svn.boost.org/trac/boost/ticket/5699
    //
    // Also: deleting a thread_specific_ptr to an object that contains
    // another thread_specific_ptr can lead to corrupting an internal
    // map.
    "thread_specific_ptr" :
    "There are known bugs and performance downsides to the use of "
    "this class. Use folly::ThreadLocal instead.\n",
  ];

  foreach (ref t; v) {
    if (t.type_ != tk!"identifier") continue;
    auto warnIt = t.value_ in warnings;
    if (!warnIt) continue;
    lintError(t, *warnIt);
    ++result;
  }

  return result;
}

/*
 * Lint check: disallow namespace-level static specifiers in C++ headers
 * since it is either redundant (such as for simple integral constants)
 * harmful (generates unnecessary code in each TU). Find more information
 * here: https://our.intern.facebook.com/intern/tasks/?t=2435344
*/
uint checkNamespaceScopedStatics(string fpath, Token[] v) {
  if (!isHeader(fpath)) {
    // This check only looks at headers. Inside .cpp files, knock
    // yourself out.
    return 0;
  }

  uint result = 0;
  for (; !v.empty; v.popFront) {
    if (v.atSequence(tk!"namespace", tk!"identifier", tk!"{")) {
      // namespace declaration. Reposition the iterator on TK_LCURL
      v.popFrontN(2);
    } else if (v.atSequence(tk!"namespace", tk!"{")) {
      // nameless namespace declaration. Reposition the iterator on TK_LCURL.
      v.popFront;
    } else if (v.front.type_ == tk!"{") {
      // Found a '{' not belonging to a namespace declaration. Skip the block,
      // as it can only be an aggregate type, function or enum, none of
      // which are interesting for this rule.
      v = skipBlock(v);
    } else if (v.front.type_ == tk!"static") {
      lintWarning(v.front,
                  "Avoid using static at global or namespace scope "
                  "in C++ header files.\n");
      ++result;
    }
  }

  return result;
}

/*
 * Lint check: disallow the declaration of mutex holders
 * with no name, since that causes the destructor to be called
 * on the same line, releasing the lock immediately.
*/
uint checkMutexHolderHasName(string fpath, Token[] v) {
  if (getFileCategory(fpath) == FileCategory.source_c) {
    return 0;
  }

  bool[string] mutexHolderNames = ["lock_guard":1];
  uint result = 0;

  for (; !v.empty; v.popFront) {
    if (v.atSequence(tk!"identifier", tk!"<")) {
      if (v.front.value_ in mutexHolderNames) {
        v.popFront;
        v = skipTemplateSpec(v);
        if (v.atSequence(tk!">", tk!"(")) {
          lintError(v.front, "Mutex holder variable declared without a name, "
              "causing the lock to be released immediately.\n");
          ++result;
        }
      }
    }
  }

  return result;
}

/*
 * Util method that checks ppath only includes files from `allowed` projects.
 */
uint checkIncludes(
    string ppath,
    Token[] v,
    const string[] allowedPrefixes,
    void function(CppLexer.Token, const string) fn) {
  uint result = 0;

  // Find all occurrences of '#include "..."'. Ignore '#include <...>', since
  // <...> is not used for fbcode includes.
  for (auto it = v; !it.empty; it.popFront) {
    if (it.atSequence(tk!"#", tk!"identifier", tk!"string_literal")
        && it[1].value_ == "include") {
      it.popFrontN(2);
      auto includePath = it.front.value_[1 .. $-1];

      // Includes from other projects always contain a '/'.
      auto slash = includePath.findSplitBefore("/");
      if (slash[1].empty) continue;

      // If this prefix is allowed, continue
      if (allowedPrefixes.any!(x => includePath.startsWith(x))) continue;

      // If the include is followed by the comment 'nolint' then it is ok.
      auto nit = it.save;
      nit.popFront; // Do not increment 'it' - increment a copy.
      if (nit.empty || nit.front.precedingWhitespace_.canFind("nolint")) {
        continue;
      }

      // Finally, the lint error.
      fn(it.front, "Open Source Software may not include files from "
          "other fbcode projects (except what's already open-sourced). "
          "If this is not an fbcode include, please use "
          "'#include <...>' instead of '#include \"...\"'. "
          "You may suppress this warning by including the "
          "comment 'nolint' after the #include \"...\".\n");
      ++result;
    }
  }
  return result;
}

/*
 * Lint check: prevent OSS-fbcode projects from including other projects
 * from fbcode.
 */
uint checkOSSIncludes(string fpath, Token[] v) {
  // strip fpath of '.../fbcode/', if present
  auto ppath = fpath.findSplitAfter("/fbcode/")[1];

  alias void function(CppLexer.Token, const string) Fn;

  import std.typecons;
  Tuple!(string, string[], Fn)[] projects = [
    tuple("folly/", ["folly/"], &lintError),
    tuple("hphp/", ["hphp/", "folly/"], &lintError),
    tuple("thrift/", ["thrift/", "folly/"], &lintError),
    tuple("ti/proxygen/lib/",
          ["ti/proxygen/lib/", "folly/", "thrift/", "configerator/structs/"],
          &lintWarning),
  ];

  foreach (ref p; projects) {
    // Only check for OSS projects
    if (!ppath.startsWith(p[0])) continue;

    // <OSS>/facebook is allowed to include non-OSS code
    if (ppath.startsWith(p[0] ~ "facebook/")) return 0;

    return checkIncludes(ppath, v, p[1], p[2]);
  }

  return 0;
}

/*
 * Starting from a left parent brace, skips until it finds the matching
 * balanced right parent brace.
 * Returns: iterator pointing to the final TK_RPAREN
 */
R skipParens(R)(R r) {
  enforce(r.front.type_ == tk!"(");

  uint openParens = 1;
  r.popFront;
  for (; r.front.type_ != tk!"\0"; r.popFront) {
    if (r.front.type_ == tk!"(") {
      ++openParens;
      continue;
    }
    if (r.front.type_ == tk!")") {
      if (!--openParens) {
        break;
      }
      continue;
    }
  }
  return r;
}

/*
 * Lint check: disable use of "break"/"continue" inside
 * SYNCHRONIZED pseudo-statements
*/
uint checkBreakInSynchronized(string fpath, Token[] v) {
  /*
   * structure about the current statement block
   * @name: the name of statement
   * @openBraces: the number of open braces in this block
  */
  struct StatementBlockInfo {
    string name;
    uint openBraces;
  };

  uint result = 0;
  StatementBlockInfo[] nestedStatements;

  for (Token[] tox = v; !tox.empty; tox.popFront) {
    if (tox.front.type_.among(tk!"while", tk!"switch", tk!"do", tk!"for")) {
      StatementBlockInfo s;
      s.name = tox.front.value_;
      s.openBraces = 0;
      nestedStatements ~= s;

      //skip the block in "(" and ")" following "for" statement
      if (tox.front.type_ == tk!"for") {
        tox.popFront;
        tox = skipParens(tox);
      }
      continue;
    }

    if (tox.front.type_ == tk!"{") {
      if (!nestedStatements.empty)
        nestedStatements.back.openBraces++;
      continue;
    }

    if (tox.front.type_ == tk!"}") {
      if (!nestedStatements.empty) {
        nestedStatements.back.openBraces--;
        if(nestedStatements.back.openBraces == 0)
          nestedStatements.popBack;
      }
      continue;
    }

    //incase there is no "{"/"}" in for/while statements
    if (tox.front.type_ == tk!";") {
      if (!nestedStatements.empty &&
          nestedStatements.back.openBraces == 0)
        nestedStatements.popBack;
      continue;
    }

    if (tox.front.type_ == tk!"identifier") {
      string strID = tox.front.value_;
      if (strID.among("SYNCHRONIZED", "UNSYNCHRONIZED", "TIMED_SYNCHRONIZED",
            "SYNCHRONIZED_CONST", "TIMED_SYNCHRONIZED_CONST")) {
        StatementBlockInfo s;
        s.name = "SYNCHRONIZED";
        s.openBraces = 0;
        nestedStatements ~= s;
        continue;
      }
    }

    if (tox.front.type_.among(tk!"break", tk!"continue")) {
      if (!nestedStatements.empty &&
        nestedStatements.back.name == "SYNCHRONIZED") {
        lintError(tox.front, "Cannot use break/continue inside "
          "SYNCHRONIZED pseudo-statement\n"
        );
        ++result;
      }
      continue;
    }
  }
  return result;
}
