cimport cython
cimport bmfmaw.BCFastq
cimport bmfutil.HTSUtils
from bmfmaw.BCFastq cimport cMakeTagComment
ctypedef bmfutil.HTSUtils.pFastqFile pFastqFile_t
ctypedef bmfutil.HTSUtils.pFastqProxy pFastqProxy_t
ctypedef cython.str cystr
ctypedef double double_t
