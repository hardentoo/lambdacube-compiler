#!/bin/bash -e

UNIT_TEST_PARAMS="--quickcheck-max-size 30 --quickcheck-tests 100"

if [ "$1" == "--profile" ] ; then
  shift
  cabal install --only-dependencies --enable-library-profiling --enable-executable-profiling
  cabal configure --flags "profiling testsuite -cli" --enable-library-profiling --enable-executable-profiling
  set +e
  RESULT_UNITTESTS=0
  cabal run lambdacube-compiler-test-suite -- -r -iperformance -i.ignore $@ +RTS -p
  RESULT_TESTS=`echo $?`
elif [ "$1" == "--coverage" ] ; then
  shift
  set +e
  cabal install --only-dependencies
  cabal configure --flags "coverage alltest"
  cabal run lambdacube-compiler-unit-tests -- $UNIT_TEST_PARAMS
  RESULT_UNITTESTS=`echo $?`
  cabal run lambdacube-compiler-coverage-test-suite -- -iperformance -i.ignore -r $@
  RESULT_TESTS=`echo $?`
  ./create-test-report.sh
  rm lambdacube-compiler-coverage-test-suite.tix
else
  set +e
  cabal install --only-dependencies -j1
  cabal run lambdacube-compiler-unit-tests -- $UNIT_TEST_PARAMS
  RESULT_UNITTESTS=`echo $?`
  cabal run lambdacube-compiler-test-suite -- -iperformance -i.ignore -r $@
  RESULT_TESTS=`echo $?`
fi

if [[ $RESULT_UNITTESTS -ne 0 ]]; then
  echo "***************************"
  echo "* Unit tests are failing. *"
  echo "***************************"
fi

if [[ $RESULT_TESTS -ne 0 ]]; then
  echo "*******************************"
  echo "* Compiler tests are failing. *"
  echo "*******************************"
fi

exit $((RESULT_TESTS + RESULT_UNITTESTS))
