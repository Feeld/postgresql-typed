{-# LANGUAGE CPP, FlexibleInstances, MultiParamTypeClasses, ScopedTypeVariables, FunctionalDependencies, UndecidableInstances, DataKinds, DefaultSignatures, PatternGuards, GADTs, TemplateHaskell #-}
-- |
-- Module: Database.PostgreSQL.Typed.Dynamic
-- Copyright: 2015 Dylan Simon
-- 
-- Automatic (dynamic) marshalling of PostgreSQL values based on Haskell types (not SQL statements).
-- This is intended for direct construction of queries and query data, bypassing the normal SQL type inference.

module Database.PostgreSQL.Typed.Dynamic 
  ( PGRep(..)
  , pgLiteralString
  , pgSafeLiteral
  , pgSafeLiteralString
  , pgSubstituteLiterals
  ) where

import Control.Applicative ((<$>))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Monoid ((<>))
import Data.Int
#ifdef USE_SCIENTIFIC
import Data.Scientific (Scientific)
#endif
import Data.String (fromString)
#ifdef USE_TEXT
import qualified Data.Text as T
#endif
import qualified Data.Time as Time
#ifdef USE_UUID
import qualified Data.UUID as UUID
#endif
import Language.Haskell.Meta.Parse (parseExp)
import qualified Language.Haskell.TH as TH

import Database.PostgreSQL.Typed.Internal
import Database.PostgreSQL.Typed.Types

-- |Represents canonical/default PostgreSQL representation for various Haskell types, allowing convenient type-driven marshalling.
class PGType t => PGRep t a | a -> t where
  pgTypeOf :: a -> PGTypeName t
  pgTypeOf _ = PGTypeProxy
  pgEncodeRep :: a -> PGValue
  default pgEncodeRep :: PGParameter t a => a -> PGValue
  pgEncodeRep x = pgEncodeValue unknownPGTypeEnv (pgTypeOf x) x
  pgLiteralRep :: a -> BS.ByteString
  default pgLiteralRep :: PGParameter t a => a -> BS.ByteString
  pgLiteralRep x = pgLiteral (pgTypeOf x) x
  pgDecodeRep :: PGValue -> a
#ifdef USE_BINARY_XXX
  default pgDecodeRep :: PGBinaryColumn t a => PGValue -> a
  pgDecodeRep (PGBinaryValue v) = pgDecodeBinary unknownPGTypeEnv (PGTypeProxy :: PGTypeName t) v
#else
  default pgDecodeRep :: PGColumn t a => PGValue -> a
#endif
  pgDecodeRep (PGTextValue v) = pgDecode (PGTypeProxy :: PGTypeName t) v
  pgDecodeRep _ = error $ "pgDecodeRep " ++ pgTypeName (PGTypeProxy :: PGTypeName t) ++ ": unsupported PGValue"

pgLiteralString :: PGRep t a => a -> String
pgLiteralString = BSC.unpack . pgLiteralRep

-- |Produce a safely type-cast literal value for interpolation in a SQL statement.
pgSafeLiteral :: PGRep t a => a -> BS.ByteString
pgSafeLiteral x = pgLiteralRep x <> BSC.pack "::" <> fromString (pgTypeName (pgTypeOf x))

pgSafeLiteralString :: PGRep t a => a -> String
pgSafeLiteralString x = pgLiteralString x ++ "::" ++ pgTypeName (pgTypeOf x)

instance PGRep t a => PGRep t (Maybe a) where
  pgEncodeRep Nothing = PGNullValue
  pgEncodeRep (Just x) = pgEncodeRep x
  pgLiteralRep Nothing = BSC.pack "NULL"
  pgLiteralRep (Just x) = pgLiteralRep x
  pgDecodeRep PGNullValue = Nothing
  pgDecodeRep v = Just (pgDecodeRep v)

instance PGRep "boolean" Bool
instance PGRep "oid" OID
instance PGRep "smallint" Int16
instance PGRep "integer" Int32
instance PGRep "bigint" Int64
instance PGRep "real" Float
instance PGRep "double precision" Double
instance PGRep "\"char\"" Char
instance PGRep "text" String
instance PGRep "text" BS.ByteString
#ifdef USE_TEXT
instance PGRep "text" T.Text
#endif
instance PGRep "date" Time.Day
instance PGRep "time without time zone" Time.TimeOfDay
instance PGRep "timestamp without time zone" Time.LocalTime
instance PGRep "timestamp with time zone" Time.UTCTime
instance PGRep "interval" Time.DiffTime
instance PGRep "numeric" Rational
#ifdef USE_SCIENTIFIC
instance PGRep "numeric" Scientific
#endif
#ifdef USE_UUID
instance PGRep "uuid" UUID.UUID
#endif

-- |Create an expression that literally substitutes each instance of @${expr}@ for the result of @pgSafeLiteral expr@.
-- This lets you do safe, type-driven literal substitution into SQL fragments without needing a full query, bypassing placeholder inference and any prepared queries.
-- Unlike most other TH functions, this does not require any database connection.
pgSubstituteLiterals :: String -> TH.ExpQ
pgSubstituteLiterals sql = TH.AppE (TH.VarE 'BS.concat) . TH.ListE <$> ssl (sqlSplitExprs sql) where
  ssl :: SQLSplit String True -> TH.Q [TH.Exp]
  ssl (SQLLiteral s l) = (TH.VarE 'fromString `TH.AppE` stringE s :) <$> ssp l
  ssl SQLSplitEnd = return []
  ssp :: SQLSplit String False -> TH.Q [TH.Exp]
  ssp (SQLPlaceholder e l) = do
    v <- either (fail . (++) ("Failed to parse expression {" ++ e ++ "}: ")) return $ parseExp e
    (TH.VarE 'pgSafeLiteral `TH.AppE` v :) <$> ssl l
  ssp SQLSplitEnd = return []
