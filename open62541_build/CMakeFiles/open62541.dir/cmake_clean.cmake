file(REMOVE_RECURSE
  "bin/.1.4"
  "bin/libopen62541.1.4.8.dylib"
  "bin/libopen62541.1.4.dylib"
  "bin/libopen62541.dylib"
  "bin/libopen62541.pdb"
)

# Per-language clean rules from dependency scanning.
foreach(lang C)
  include(CMakeFiles/open62541.dir/cmake_clean_${lang}.cmake OPTIONAL)
endforeach()
