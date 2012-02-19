module Angel.Data where

import Data.String.Utils (strip, split)
import qualified Data.Map as M
import System.Process (createProcess, proc, waitForProcess, ProcessHandle)
import System.Process (terminateProcess, CreateProcess(..), StdStream(..))
import Control.Concurrent.STM.TChan (TChan)
import System.IO (Handle)

-- |the whole shared state of the program; spec is what _should_
-- |be running, while running is what actually _is_ running_ currently
data GroupConfig = GroupConfig {
    spec :: SpecKey,
    running :: RunKey,
    fileRequest :: TChan FileRequest
}

-- |map program ids to relevant structure
type SpecKey = M.Map ProgramId Program
type RunKey = M.Map ProgramId (Program, Maybe ProcessHandle)
type ProgramId = String
type FileRequest = (String, TChan (Maybe Handle))

data ExecSpec = ExecStr String
              | ExecList [String]
  deriving (Show, Eq, Ord)

-- |the representation of a program is these 6 values, 
-- |read from the config file
data Program = Program {
    name :: String,
    exec :: ExecSpec,
    delay :: Int,
    minRestartDelay :: Maybe Int,
    stdout :: String,
    stderr :: String,
    workingDir :: Maybe FilePath
} deriving (Show, Eq, Ord)

-- |return a list of strings for the exec of a program.
splitExec :: Program -> [String]
splitExec p =
  case exec p of
    ExecStr s -> filter (/="") . map strip . split " " $ s
    ExecList ss -> ss

-- |Lower-level atoms in the configuration process
type Spec = [Program]

-- |a template for an empty program; the variable set to ""
-- |are required, and must be overridden in the config file
defaultProgram = Program{
    name="",
    exec=ExecStr "",
    delay=5,
    minRestartDelay=Nothing,
    stdout="/dev/null",
    stderr="/dev/null",
    workingDir = Nothing
}
