> {-# OPTIONS_GHC -fglasgow-exts #-}

> -- | 
> -- Module      : Ivor.Shell
> -- Copyright   : Edwin Brady
> -- Licence     : BSD-style (see LICENSE in the distribution)
> --
> -- Maintainer  : eb@dcs.st-and.ac.uk
> -- Stability   : experimental
> -- Portability : non-portable
> -- 
> -- Shell interface to theorem prover

> module Ivor.Shell(ShellState,
>                     runShell, importFile,
>                     getContext, newShell, 
>                     sendCommand, sendCommandIO, addTactic,
>                     extendParser, configureEq,
>                     shellParseTerm, showProofState) where

> import Ivor.ShellParser
> import Ivor.TermParser
> import Ivor.TT as TT
> import Ivor.Equality
> import Ivor.Gadgets
> import Ivor.Primitives
> -- import Ivor.Plugin

> import IO
> import System
> import System.Environment
> import System.Directory
> import System.IO
> import Char
> import Debug.Trace

> import Text.ParserCombinators.Parsec

> data ShellState = Shell {
>                          repldata :: Maybe (String, String, String),
>                          prompt :: String,
>                          finished :: Bool,
>                          context :: !Context,
>                          response :: String,
>                          usertactics :: forall m.Monad m => [(String, String -> Goal -> Context -> m Context)],
>                          imported :: [String],
>                          extensions :: Maybe (Parser ViewTerm)
>                          }

> respond, respondLn :: ShellState -> String -> ShellState
> respond st str = st { response = (response st) ++ str }
> respondLn st str = st { response = (response st) ++ str ++ "\n" }

> clearResponse st = st { response = "" }

> -- | Create a new shell state.
> newShell :: Context -- ^ Initial system state
>          -> ShellState
> newShell ctxt = Shell Nothing "> " False ctxt "" [] [] Nothing

> -- | Add a user defined tactic to the shell.
> addTactic :: String -- ^ Tactic name.
>           -> (String -> Tactic) -- ^ Tactic function. The argument is whatever was input on the shell; the function is resposible for parsing this.
>           -> ShellState -- ^ Shell to which to add the tactic.
>           -> ShellState
> addTactic nm tac st = st { usertactics = (nm,tac):(usertactics st) }

> -- | Add another parsing rule for parsing terms.
> extendParser :: ShellState -> Parser ViewTerm -> ShellState
> extendParser st ext = case (extensions st) of
>                          Nothing -> st { extensions = Just ext }
>                          Just p -> st { extensions = Just (p <|> ext) }

> -- | Parse a term using the shell's current parser extensions
> shellParseTerm :: ShellState -> Parser ViewTerm
> shellParseTerm st = pTerm (extensions st) 

> -- | Get the system state from a finished shell
> getContext :: ShellState -> Context
> getContext = context

> readToSemi :: IO String
> readToSemi = 
>   do c <- getChar
>      if (c==';') 
>         then return ";"
>         else do s <- readToSemi
>                 return (c:s)

 output st = hPutStr (outputstream st)
 outputLn st x = output st (x++"\n")

> runCommand :: (Monad m) => Command -> ShellState -> m ShellState
> runCommand (Def nm tm) st = do ctxt <- addDef (context st) (name nm) tm
>                                return st { context = ctxt }
> runCommand (TypedDef nm tm ty) st = do
>     ctxt <- addTypedDef (context st) (name nm) tm ty
>     return st { context = ctxt }
> runCommand (Data dat) st = do ctxt <- addData (context st) dat
>                               return st { context = ctxt }
> runCommand (Axiom nm tm) st = do ctxt <- addAxiom (context st) (name nm) tm
>                                  return st { context = ctxt }
> runCommand (Declare nm tm) st = do ctxt <- declare (context st) (name nm) tm
>                                    return st { context = ctxt }
> runCommand (Theorem nm ty) st = do ctxt <- theorem (save (context st)) 
>                                                    (name nm) ty
>                                    let st' = respond st $
>                                          showProofState st { context = ctxt }
>                                    return st' { context = ctxt }
> runCommand (Interactive nm ty) st = do 
>     ctxt <- interactive (save (context st)) 
>                 (name nm) ty
>     let st' = respond st $
>           showProofState st { context = ctxt }
>     return st' { context = ctxt }
> runCommand (Forget n) st = do 
>     ctxt <- forgetDef (context st) (name n)
>     return $ (respondLn st ("Forgotten back to " ++ n)) 
>                { context = ctxt }
> runCommand (EvalTerm exp) st = do 
>     tm <- check (context st) exp
>     return (respondLn st (show (eval (context st) tm)))
> runCommand (Print n) st = do 
>     case (getDef (context st) (name n)) of
>        Just tm -> return (respondLn st (show (view tm)))
>        _ -> do tm <- check (context st) n
>                case view tm of
>                  (Name TypeCon _) -> do
>                     -- erule <- getElimRule (context st) (name n) Elim
>                     -- return (respondLn st $ "Type constructor\n" ++ show erule)
>                     return (respondLn st "Type constructor")
>                  (Name ElimOp _) -> return (respondLn st "Elimination operator")
>                  (Name Free _) -> return (respondLn st "Undefined function")
>                  (Name DataCon _) -> return (respondLn st "Data constructor")
>                  _ -> fail "Unknown definition"
> runCommand (Check exp) st = do 
>     tm <- check (context st) exp
>     return (respondLn st (show (viewType tm)))
> runCommand (Freeze n) st = do ctxt <- freeze (context st) (name n)
>                               return st { context = ctxt }
> runCommand (Thaw n) st = do ctxt <- thaw (context st) (name n)
>                             return st { context = ctxt }
> runCommand (Focus n) st = do ctxt <- focus (goal n) (context st) 
>                              return st { context = ctxt }
> runCommand (Dump n) st = do 
>     let ds = getAllDefs (context st)
>     return (respondLn st (dumpAll n ds))
> runCommand (ReplData eq repl sym) st 
>     = return st { repldata = Just (eq, repl, sym) }
> runCommand Prf st = do 
>     tm <- proofterm (context st) 
>     return (respondLn st (show tm))
> runCommand PrfState st = do let st' = respond st $ showProofState st
>                             return st'
> runCommand Qed st = do ctxt <- qed (context st) 
>                        return st { context = (clearSaved ctxt) }
> runCommand Suspend st = do let st' = respondLn st "Suspending Proof"
>                            return st' { context = suspend (context st) }
> runCommand (Resume n) st = do ctxt <- resume (context st) (name n)
>                               let st' = respondLn st $ "Resuming proof of " ++ n
>                               ctxt <- if (numUnsolved ctxt) == 1
>                                        then attack defaultGoal ctxt
>                                        else return ctxt
>                               let st'' = respond st' $
>                                          showProofState st' { context = ctxt }
>                               return st'' { context = ctxt }
> runCommand Undo st = do ctxt <- restore (context st)
>                         let st' = respondLn st $ 
>                                      showProofState st { context = ctxt }
>                         return st' { context = ctxt }
> runCommand (GenRec n) st = do ctxt <- addGenRec (context st) (name n)
>                               let st' = respondLn st $ "Added general recursion rule"
>                               return st' { context = ctxt }
> runCommand (JMEq n c) st = do ctxt <- addEquality (context st) (name n) 
>                                         (name c)
>                               let st' = respondLn st $ "Added dependent equality"
>                               return st' { context = ctxt }
> runCommand Primitives st = do let st' = extendParser st parsePrimitives
>                               ctxt <- addPrimitives (context st')
>                               return st' { context = ctxt }
> runCommand Drop st = return st { finished = True }
> runCommand (Load f) st = fail "Can only load in a shell -- use importFile instead"
> runCommand (Plugin f) st = fail "Can only load plugin in a shell -- use Plugin.load instead"
> runCommand (Compile f) st = fail "Can only Compile in a shell -- use 'compile' function instead"

> runTactic _ _ Attack = attack
> runTactic _ _ (AttackWith n) = attackWith (name n)
> runTactic _ _ (Claim n tm) = claim (name n) tm
> runTactic _ _ (Local n tm) = \g ctxt -> do
>                            ctxt <- claim (name n) tm g ctxt
>                            focus (goal n) ctxt
> runTactic _ _ (Refine tm args) = refineWith tm args
> runTactic _ _ Solve = solve
> runTactic _ _ (Fill tm) = fill tm
> runTactic _ _ ReturnTac = returnComputation
> runTactic _ _ QuoteTac = quoteVal
> runTactic _ _ (CallTac tm) = call tm
> runTactic _ _ Abandon = abandon
> runTactic _ _ (Rename n) = rename (name n)
> runTactic _ _ Intro = intro
> runTactic _ _ (IntroName n) = introName (name n)
> runTactic _ _ Intros = intros
> runTactic _ _ (IntrosNames ns) = introsNames (map name ns)
> runTactic _ _ (Equiv tm) = equiv tm
> runTactic _ _ (AddArg nm tm) = addArg (name nm) tm
> runTactic _ _ (Generalise False tm) = generalise tm
> runTactic _ _ (Generalise True tm) = dependentGeneralise tm
> runTactic _ (Just (eq,repl,sym)) (Replace tm f) 
>     = replace eq repl sym tm f
> runTactic _ Nothing (Replace _ _) = fail "replace not configured"
> runTactic _ _ (Axiomatise n ns) = axiomatise (name n) (map name ns)
> runTactic _ _ Normalise = compute
> runTactic _ _ (Unfold n) = unfold (name n)
> runTactic _ _ Trivial = trivial
> runTactic _ _ (By tm) = by tm
> runTactic _ _ (Induction tm) = induction tm
> runTactic _ _ (Cases tm) = cases tm
> runTactic tacs _ (UserTactic tac tm)  = \g ctxt -> do
>     case lookup tac tacs of
>          (Just t) -> t tm g ctxt
>          Nothing -> fail $ "User tactic "++tac++" undefined"

> dumpAll :: String -> [(Name,Term)] -> String
> dumpAll pat [] = ""
> dumpAll pat ((n,ty):xs) 
>         | sublist pat (length pat) (show n) = 
>             show n ++" : " ++ show (view ty) ++ "\n" ++ dumpAll pat xs
>         | otherwise = dumpAll pat xs
>    where sublist pat i xs | i > length xs = False
>                           | take i xs == pat = True
>          sublist pat i (x:xs) = sublist pat i xs

Deal with commands that do IO here, so we can have a separate processing
function which doesn't need to be in the IO Monad.

> process :: Result Input -> ShellState -> IO ShellState
> process (Failure err) st = return $ respondLn st err
> process (Success (Command (Load f))) st = do importFile f st
> process (Success (Command (Plugin f))) st = do 
>     fail "Plugins currently unsupported"
>     {-
>     (ctxt, exts) <- load f (context st)
>     let st' = st { context = ctxt }
>     let st'' = case exts of
>                    Nothing -> st' 
>                    Just p -> extendParser st' p
>     return st'' -}
> process (Success (Command (Compile f))) st = do compile (context st) f
>                                                 putStrLn $ "Output " ++ f ++ ".hs"
>                                                 return st
> process x st = processInput x st

> processInput :: Monad m => Result Input -> ShellState -> m ShellState
> processInput (Failure err) st = return $ respondLn st err
> processInput (Success (Command cmd)) st = runCommand cmd st
> processInput (Success (Tactic goal tac)) st 
>     = do let ctxt = save (context st)
>          ctxt <- runTactic (usertactics st) (repldata st) 
>                     tac goal ctxt
>          ctxt <- keepSolving defaultGoal ctxt
>          ctxt <- if ((numUnsolved ctxt) > 0) 
>                    then beta defaultGoal ctxt
>                    else return ctxt
>          let st' = respond st $ showProofState $ st { context = ctxt }
>          return st' { context = ctxt }

> -- | Get a string representation of the current proof state
> showProofState :: ShellState -> String
> showProofState st 
>     | not (proving ctxt) = ""
>     | null $ getGoals ctxt = "\nNo more goals\n\n"
>     | otherwise = let (g:gs) = getGoals ctxt in
>                      "\n" ++ showGoalState g ++
>                      "\nOther goals: " ++ show gs ++ "\n\n"
>  where
>   ctxt = context st
>   showGoalState :: Goal -> String
>   showGoalState g = let (Just gd) = goalData ctxt True g
>                         env = bindings gd
>                         ty = goalType gd
>                         nm = goalName gd in
>                        showEnv (reverse env) ++ "\n" ++
>                        "--------------------------------\n" ++
>                        show nm ++ " ? " ++ show (view ty) ++ "\n"
>   showEnv [] = ""
>   showEnv ((n,ty):xs) = show n ++ " : " ++ show (view ty) ++ "\n" ++
>                            showEnv xs

> loop :: ShellState -> IO ShellState
> loop st = do putStr (prompt st)
>              hFlush stdout
>              inp <- readToSemi
>              st' <- catch (process (parseInput (extensions st) (gettacs (usertactics st)) inp) st)
>                      (\e -> do return $ respondLn st (show e))
>              putStr $ (response st')
>              if (finished st') 
>                 then return (clearResponse st')
>                 else catch (loop (clearResponse st'))
>                          (\e -> return st')

> -- | Set up the equality type, for use by the 'replace' tactic
> configureEq :: String 
>             -> String 
>             -> String 
>             -> ShellState -> ShellState
> configureEq eq repl sym shell = shell { repldata = Just (eq,repl,sym) }

> -- | Run a command shell.
> runShell :: String -- ^ Prompt string
>          -> ShellState -- ^ Initial state
>          -> IO ShellState
> runShell p shell = 
>     do st <- loop shell { prompt = p }
>        return st

> -- | Send a command directly to a shell
> sendCommand :: Monad m => String -> ShellState -> m ShellState
> sendCommand str st = processInput 
>                        (parseInput (extensions st) (gettacs (usertactics st)) str) $
>                          clearResponse st

Special case for importFile. Grr.

> -- | Send a command directly to a shell, allowing commands which might
> -- do IO actions.
> sendCommandIO :: String -> ShellState -> IO ShellState
> sendCommandIO str st = process
>                        (parseInput (extensions st) (gettacs (usertactics st)) str) $
>                          clearResponse st

> gettacs :: [(String, String -> Goal -> Context -> IO Context)] -> [String]
> gettacs = map fst

If the given file is already loaded, do nothing.

> -- | Import a file of shell commands.
> importFile :: FilePath -> ShellState -> IO ShellState
> importFile fp st 
>     | fp `elem` imported st = return st
>     | otherwise = do inp <- readFile fp
>                      st' <- processFile [] inp st
>                      --resp <- readFile tmpf
>                      return $ st' { imported = fp:(imported st') }
>   where processFile acc (';':rest) st = 
>             do --putStrLn ("processing"++acc)
>                st' <- sendCommandIO (acc++";") st
>                processFile [] rest st'
>         processFile acc (x:xs) st = processFile (acc++[x]) xs st
>         processFile [] [] st = return st
>         -- Now eat the whitespace at the end
>         processFile (x:xs) [] st | isSpace x = processFile xs [] st
>                                  | otherwise = fail "Unexpected end of file"

> environment :: String -> IO (Maybe String)
> environment x = catch (do e <- getEnv x
>                           return (Just e))
>                       (\_ -> return Nothing)

> tempfile :: IO (FilePath, Handle)
> tempfile = do env <- environment "TMPDIR"
>               let dir = case env of
> 		     Nothing -> "/tmp"
> 		     (Just d) -> d
>               openTempFile dir "humett.out"

