cimport pysam.cfaidx
cimport numpy as np
from numpy cimport ndarray
from bmfutil.HTSUtils cimport cystr
cimport bmfutil.HTSUtils
ctypedef bmfutil.HTSUtils.pFastqFile pFastqFile_t
ctypedef bmfutil.HTSUtils.pFastqProxy pFastqProxy_t
cdef ndarray[double] GetFamSizeStats_(pFastqFile_t FqHandle)
cdef ndarray[np.float64_t, ndim=1] InsertSizeArray_(
    pysam.calignmentfile.AlignmentFile)
