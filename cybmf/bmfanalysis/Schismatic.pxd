cimport bmfutil.HTSUtils
cimport cython
cimport pysam.calignmentfile
cimport pysam.calignedsegment

from bmfutil.HTSUtils cimport cGetBS as GetFqBS
ctypedef pysam.calignedsegment.AlignedSegment AlignedSegment_t
ctypedef bmfutil.HTSUtils.pFastqFile pFastqFile_t
ctypedef bmfutil.HTSUtils.pFastqProxy pFastqProxy_t
ctypedef cython.str cystr

cdef inline cystr GetBS(AlignedSegment_t read):
    return read.opt("BS")

cdef public list int2nuc
