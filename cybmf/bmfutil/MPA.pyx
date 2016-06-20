# cython: c_string_type=str, c_string_encoding=ascii
# cython: boundscheck=False, wraparound=False, initializedcheck=False

# Standard library imports
import logging
import uuid
import warnings
from itertools import groupby, izip
from array import array
from operator import attrgetter as oag
from subprocess import check_call
import sys

# Third party imports
import numpy as np
import cython
from pysam import AlignmentFile

# BMFTools imports
from .HTSUtils import (TrimExt, printlog as pl, BamTag, ReadsOverlap)
from .ErrorHandling import ImproperArgumentError, ThisIsMadness as Tim
from .ErrorHandling import AbortMission

# DEFINES
oagtag = oag("tag")


cdef class LayoutPos:
    """
    Holds one layout position - either part of the reference,
    part of the read, or both.

    All of these fields are chars/ints.
    pos:
        -1 if "I", -1 * read.pos if "S"
    readPos:
        -1 if "D"
    mergeAgreed:
        1 = Not merged
        0 = Merge did not agree
        2 = Merge Agreed
    base:
        ascii char/int for the base
        [ord(i) for i in 'ACGNT']
        [65, 67, 71, 78, 84]
    operation:
        ascii char/int for the operation
        [ord(i) for i in "MIDNSHP=X"]
        [77, 73, 68, 78, 83, 72, 80, 61, 88]
    """
    def __init__(self, int pos=-1, int readPos=-1,
                 char base=-1, char operation=-1,
                 int quality=-1, int agreement=-1,
                 bint merged=False, char mergeAgreed=1):
        self.pos = pos
        self.readPos = readPos
        self.operation = operation
        self.base = base
        self.quality = quality if(self.base != 78) else 0  # 78 == "N"
        self.agreement = agreement
        self.merged = merged
        self.mergeAgreed = mergeAgreed

    cpdef bint ismapped(self):
        return self.operation == 77  # 77 == "M"

    cdef bint getMergeAgreed(self):
        return self.mergeAgreed == 2

    cdef bint getMergeSet(self):
        return self.mergeAgreed != 1

    cdef cystr tostring(self):
        return "%s|%s|%s|%s|%s|%s|%s|%s" % (
            self.pos, self.readPos, chr(self.base), chr(self.operation),
            self.quality, self.agreement, self.merged, self.mergeAgreed)

    def __str__(self):
        return self.tostring()


cdef class PyLayout(object):
    """
    Holds a read and its layout information.
    The recommended method for initialization is PyLayout.fromread.
    """

    @classmethod
    def fromread(cls, pysam.calignedsegment.AlignedSegment rec,
                 pysam.calignmentfile.AlignmentFile handle):
        return cls(*makeLayoutTuple(rec, handle))

    def __getitem__(self, index):
        return self.positions[index]

    def __len__(self):
        return len(self.positions)

    cdef py_array getSeqArr(self):
        """Returns a character array of the base calls
        if the base calls aren't "D" (68)
        """
        cdef char i
        cdef LayoutPos_t pos
        return array('B', [pos.base for pos in self.positions if
                           pos.operation != 68 and
                           pos.agreement > -1])

    cpdef cystr getSeq(self):
        return self.getSeqArr().tostring()

    cdef int cGetRefPosForFirstPos(self):
        """cdef class wrapped by getRefPosForFirstPos
        """
        cdef LayoutPos_t i
        cdef int count
        for count, i in enumerate(self.positions):
            if(i.operation == 77):
                return i.pos - count

    cpdef int getRefPosForFirstPos(self):
        return self.cGetRefPosForFirstPos()

    cpdef int getAlignmentStart(self):
        cdef LayoutPos_t i
        for i in self.positions:
            if(i.operation == 77):  # operation is "M"
                return i.pos

    cpdef py_array getAgreement(self):
        """cpdef wrapper of cGetAgreement
        """
        return self.cGetAgreement()

    cdef py_array cGetAgreement(self):
        cdef LayoutPos_t pos
        # Ask if >= 0. My tests say it's ~1% faster to ask (> -1) than (>= 0).
        return array('i', [pos.agreement for
                           pos in self.positions if pos.agreement > -1])

    cdef py_array cGetQual(self):
        cdef LayoutPos_t pos
        # Ask if >= 0. My tests say it's ~1% faster to ask (> -1) than (>= 0).
        # pos.base == 66 for "B", which is a blank spot.
        # quality is set to less than 0 for an "N" cigar operation.
        return array('l', [pos.quality for
                           pos in self.positions if pos.quality > -1 and
                           pos.operation != 66])

    cpdef py_array getQual(self):
        return self.cGetQual()

    cdef cystr cGetQualString(self):
        cdef py_array tmpArr
        cdef int i
        tmpArr = array('B', [i + 33 if(i < 94) else 126 for
                             i in self.cGetQual()])
        return tmpArr.tostring()

    cpdef cystr getQualString(self):
        return self.cGetQualString()

    cdef int cGetLastRefPos(self):
        """cdef version of getLastRefPos
        """
        cdef LayoutPos_t i
        cdef int lastMPos, countFromMPos, count
        lastMPos = 0
        for count, i in enumerate(self):
            countFromMPos += 1
            if(i.operation == 77):  # 77 == M in ASCII
                lastMPos = i.pos
                countFromMPos = 0
        return lastMPos + countFromMPos

    cpdef int getLastRefPos(self):
        """
        Finds the reference position which "matches" the last base in the
        layout. This counts for any cigar operation.
        """
        return self.cGetLastRefPos()

    cpdef py_array getMergedPositions(self):
        """
        Returns the indices of the bases in the merged read
        which have been merged.
        """
        return self.cGetMergedPositions()

    cpdef py_array getMergeAgreements(self):
        """
        Returns the indices of the bases in the merged read
        which have been merged successfully.
        """
        return self.cGetMergeAgreements()

    cdef py_array cGetMergedPositions(self):
        """
        Returns the indices of the bases in the merged read
        which have been merged.
        """
        cdef LayoutPos_t lpos
        return array('h', [lpos.readPos for lpos in self.positions if
                           lpos.merged and lpos.readPos > -1])

    cdef py_array cGetMergeAgreements(self):
        """
        Returns the indices of the bases in the merged read
        which have been merged successfully.
        """
        cdef LayoutPos_t lpos
        return array('h',
                     [lpos.readPos for lpos in self.positions if
                      lpos.getMergeAgreed() and lpos.readPos > -1])

    cdef py_array cGetGenomicDiscordantPositions(self):
        """
        Returns a 1-d array of integers for genomic positions which
        were discordant between the pairs.
        """
        cdef LayoutPos_t p
        if(self.isMerged is False):
            return array('i', [])
        return array('i',
                     [p.pos for p in self.positions if
                      p.mergeAgreed == 0 and p.pos >= 0])

    cpdef py_array getReadDiscordantPositions(self):
        return self.cGetReadDiscordantPositions()

    cpdef py_array getGenomicDiscordantPositions(self):
        return self.cGetGenomicDiscordantPositions()

    cdef py_array cGetReadDiscordantPositions(self):
        """
        Returns a 1-d array of integers for genomic positions which
        were discordant between the pairs.
        """
        cdef LayoutPos_t p
        if(self.isMerged is False):
            return array('h', [])
        else:
            return array('h',
                         [p.readPos for p in self.positions if
                          p.mergeAgreed == 0 and p.readPos >= 0])

    cdef update_tags(self):
        cdef np.int16_t tmp16
        cdef int tmpInt
        cdef py_array GenDiscPos, MA_Arr, MP_Arr, ReadDiscPos
        self.tagDict["PV"] = BamTag(
            "PV", "B", self.cGetQual())
        self.tagDict["FA"] = BamTag(
            "FA", "B", self.cGetAgreement())
        if(self.isMerged is True and self.mergeAdjusted is False):
            MP_Arr = self.getMergedPositions()
            if(len(MP_Arr) != 0):
                self.tagDict["PM"] = BamTag("PM", "B", MP_Arr)
            MA_Arr = self.getMergeAgreements()
            if(len(MA_Arr) != 0):
                self.tagDict["MA"] = BamTag("MA", "B", MA_Arr)
            GenDiscPos = self.cGetGenomicDiscordantPositions()
            ReadDiscPos = self.cGetReadDiscordantPositions()
            if(len(GenDiscPos) != 0):
                self.tagDict["DG"] = BamTag("DG", "B", GenDiscPos)
                self.tagDict["DR"] = BamTag("DR", "B", ReadDiscPos)
            # Update it for the merged world!
            # Original template length
            self.tagDict["ot"] = BamTag("ot", "i", self.tlen)
            # Original mate position
            self.tagDict["mp"] = BamTag("mp", "i", self.pnext)
            # Original mapping quality
            self.tagDict["om"] = BamTag("om", "i", self.mapq)
            # Original mapped position
            self.tagDict["op"] = BamTag("op", "i", self.InitPos)
            self.tagDict["MP"] = BamTag("MP", "A", "T")
            # self.tagDict["FM"].value *= 2
            self.mapq = 255
            self.mergeAdjusted = True
            PyDict_DelItemString(self.tagDict, "MD")

    def update(self):
        cdef LayoutPos_t pos
        cdef int count
        self.update_tags()
        if(self.isMerged):
            self.tlen = (self.cGetLastRefPos() -
                         self.cGetRefPosForFirstPos() + 1)
            self.pnext = 0
            self.rnext = "="
            self.flag = 2 + (16 if(self.is_reverse) else 32)
            for count, pos in enumerate(self):
                pos.readPos = count

    @cython.returns(py_array)
    def getOperations(self):
        """
        Returns a list of operation objects in a char array.
        """
        cdef LayoutPos_t pos
        # Skip this operation if the operation is 83"
        return array("B", [pos.operation for pos in
                           self.positions])

    cdef cystr cGetCigarString(self):
        cdef char k
        cdef object g
        return "".join([opLenToStr(k, len(list(g))) for
                        k, g in groupby(self.getOperations())])

    cpdef cystr getCigarString(self):
        return self.cGetCigarString()

    @cython.returns(list)
    def get_tag_strings(self, object oagtag=oagtag):
        cdef BamTag_t BT
        return [str(BT) for BT in sorted(self.tagDict.itervalues(),
                                         key=oagtag)]

    def getFlag(self):
        self.update()
        return self.flag

    def __str__(self):
        """
        Converts the record into a SAM record.
        Note: the position is incremented by 1 because SAM positions are
        1-based instead of 0-based.
        """
        self.update()
        cdef cystr seq, qual
        seq = self.getSeq()
        qual = self.getQualString()
        try:
            assert len(seq) == len(qual)
        except AssertionError:
            raise Tim("Length of seq " + str(len(seq)) +
                      " is not equal to the length of qual " +
                      str(len(qual)) + ". Abort mission!" +
                      "Read name: %s" % self.Name)
        return "\t".join(
                [self.Name, str(self.getFlag()), self.contig,
                 "%s\t%s" % (self.getAlignmentStart() + 1, self.mapq),
                 self.cGetCigarString(),
                 "%s\t%s\t%s" % (self.rnext, self.pnext + 1, self.tlen),
                 seq, qual] +
                self.get_tag_strings()) + "\n"

    def __init__(self, pysam.calignedsegment.AlignedSegment rec,
                 list layoutPositions, int firstMapped,
                 pysam.calignmentfile.AlignmentFile handle):
        cdef tuple tag
        self.mapq = rec.mapq
        self.positions = layoutPositions
        self.firstMapped = firstMapped
        self.InitPos = rec.pos
        self.Name = rec.query_name
        self.contig = handle.getrname(rec.reference_id)
        self.flag = rec.flag
        self.aend = rec.aend
        # When the get_tags(with_value_type=True) is implemented,
        # then switch the code over.
        # Then I can change the way I make BAM tags, since
        # with_value_type is the optional argument to add to get_tags
        # on a pysam.calignedsegment.AlignedSegment object.
        # This will ensure that I don't need to already know
        # the type beforehand. (IE, get rid of the type dict)
        self.tagDict = {tag[0]: BamTag.fromtuple(tag) for tag
                        in rec.get_tags() if tag[0] not in ["PV", "FA"]}
        self.rnext = handle.getrname(rec.mrnm)
        self.pnext = rec.mpos
        self.tlen = rec.tlen
        self.isMerged = (rec.has_tag("MP") and rec.opt("MP") == "T")
        self.is_reverse = rec.is_reverse
        self.mergeAdjusted = False

    cdef bint test_merge_success(self):
        cdef char i
        if(not self.isMerged):
            return False
        for char in self.getOperations():
            if char == 78:
                return False
        return True


cpdef PyLayout_t MergeLayoutsToLayout(PyLayout_t L1, PyLayout_t L2):
    """
    Warning: This modifies L1 in-place under the assumption
    that the input arguments are to be ignored. Do not attempt
    to use L1 as the original layout.
    """
    cdef list layoutList
    cdef cystr Name
    cdef bint Success
    cdef ListBool ret
    ret = cMergeLayoutsToList(L1, L2)
    if(ret.Bool is False):
        L1.tagDict["MP"] = BamTag("MP", tagtype="A", value="F")
        L2.tagDict["MP"] = BamTag("MP", tagtype="A", value="F")
        return None
    L1.positions = ret.List
    L1.tagDict["MP"] = BamTag("MP", tagtype="A", value="T")
    L1.isMerged = True
    L1.update()
    return L1


cpdef bint LayoutsOverlap(PyLayout_t L1, PyLayout_t L2):
    """
    This should ideally only be called on reads which are already
    established as members in proper pairs.
    """
    cdef int pos1, pos2, readlen, end1, end2
    cdef LayoutPos_t tmpPos
    warnings.warn("LayoutsOverlap deprecated - check if reads overlap"
                  " before creating PyLayout objects.",
                  DeprecationWarning)
    pos1 = L1.getRefPosForFirstPos()
    pos2 = L2.getRefPosForFirstPos()
    end1 = L1.cGetLastRefPos()
    end2 = L2.cGetLastRefPos()
    if(pos1 > end2 or pos2 > end1):
        return False
    else:
        return True


cdef ListBool cMergeLayoutsToList(PyLayout_t L1, PyLayout_t L2):
    """
    Merges two Layouts into a list of layout positions.

    First, it takes the positions before the overlap starts.
    Then it merges the overlap position by position.
    Then it takes the positions after the overlap ends.
    :param PyLayout_t L1: One Layout object
    :param PyLayout_t L2: Another Layout object
    :param oagsk: A method caller function. Locally redefined for speed.

    :return list Merged Positions
    :return bool Whether the merge was successful
    """
    from sys import stderr
    cdef int offset
    cdef PyLayout_t tmpPos
    cdef LayoutPos_t pos1, pos2
    cdef ListBool ret
    cdef list MiddleList
    '''
    if(LayoutsOverlap(L1, L2) is False):
        print("LayoutsOverlap is reported to be False.")
        return ListBool([], False)
    '''
    if(L1.cGetRefPosForFirstPos() > L2.cGetRefPosForFirstPos()):
        tmpPos = L1
        L1 = L2
        del tmpPos
    offset = L2.cGetRefPosForFirstPos() - L1.cGetRefPosForFirstPos()
    ret = ListBool()
    ret.List = L1[:offset]
    cdef size_t count = 0
    for pos1 in L1[offset:]:
        pos2 = L2[count]
        if(pos1.operation == pos2.operation):
            ret.List.append(cMergePositions(pos1, pos2))
            count += 1
        elif(pos1.operation == 68):
            ret.List.append(pos1)
        elif(pos2.operation == 68):
            ret.List.append(pos2)
            count += 1
        else:
            ret.List.append(cMergePositions(pos1, pos2))
            count += 1
    ret.List += L2[count:]
    ret.Bool = True
    return ret


cpdef LayoutPos_t MergePositions(LayoutPos_t pos1, LayoutPos_t pos2):
    """Merges two positions. Order does matter - pos1 overrides pos2 when
    pos2 is soft-clipped.
    """
    return cMergePositions(pos1, pos2)


cdef LayoutPos_t cMergePositions(LayoutPos_t pos1, LayoutPos_t pos2):
    """
    cdef function wrapped by MergePositions
    """
    if(pos1.base == pos2.base):
        if(pos2.operation == pos1.operation):
            return LayoutPos(pos1.pos, pos1.readPos, pos1.base,
                             pos1.operation,
                             MergeAgreedQualities(pos1.quality, pos2.quality),
                             pos1.agreement + pos2.agreement, merged=True,
                             mergeAgreed=2)
        elif(pos2.operation == 83):  # if pos2.operation is "S"
            return LayoutPos(pos1.pos, pos1.readPos, pos1.base,
                             pos1.operation,
                             MergeAgreedQualities(pos1.quality, pos2.quality),
                             pos1.agreement + pos2.agreement,
                             merged=True, mergeAgreed=2)
        elif(pos1.operation == 83):
            return LayoutPos(pos2.pos, pos1.readPos, pos1.base,
                             pos2.operation,
                             MergeAgreedQualities(pos1.quality, pos2.quality),
                             pos1.agreement + pos2.agreement,
                             merged=True, mergeAgreed=2)
        else:
            return (LayoutPos(pos1.pos, pos1.readPos, 78, 78,
                              -137, -137,
                              merged=True, mergeAgreed=0) if
                    (pos1.operation != 68 and pos1.operation != 73) else
                    LayoutPos(pos1.pos, pos1.readPos, 78, 78, -137, -137,
                              merged=True, mergeAgreed=0))
    elif(pos1.operation == pos2.operation):
        if(pos1.quality > pos2.quality):
            return LayoutPos(
                pos1.pos, pos1.readPos, pos1.base, pos1.operation,
                MergeDiscQualities(pos1.quality, pos2.quality), pos1.agreement,
                merged=True, mergeAgreed=0)
        else:
            return LayoutPos(
                pos1.pos, pos1.readPos, pos2.base, pos1.operation,
                MergeDiscQualities(pos2.quality, pos1.quality), pos2.agreement,
                merged=True, mergeAgreed=0)
    else:
        if(pos2.base == 78 or pos2.operation == 83):
            return LayoutPos(pos1.pos, pos1.readPos, pos1.base,
                             pos1.operation, pos1.quality,
                             pos1.agreement, merged=True,
                             mergeAgreed=0)
        else:
            return LayoutPos(pos1.pos, pos1.readPos, pos1.base, 78, -137,
                             -137, merged=True, mergeAgreed=0)


@cython.returns(tuple)
def makeLayoutTuple(pysam.calignedsegment.AlignedSegment rec,
                    pysam.calignmentfile.AlignmentFile handle):
    cdef tuple pair
    cdef int offset, firstMapped, i
    cdef list PosList
    offset = 0
    firstMapped = -1
    PosList = []
    for i, pair in enumerate(rec.cigar):
        PosList += CigarOpToLayoutPosList(offset, pair[0], pair[1], rec)
        if(pair[0] == 0 and firstMapped < 0):  # 0->"M"
            firstMapped = offset  # Facilitates coordinating merging pairs.
        offset += pair[1]
    return (rec, PosList, firstMapped, handle)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef int getLayoutLen(AlignedSegment_t read):
    return len(read.aligned_pairs)


cdef list CigarOpToLayoutPosList(int offset, int cigarOp, int cigarLen,
                                 pysam.calignedsegment.AlignedSegment rec):
    cdef object x0, x1
    cdef char CigarChar
    cdef py_array quals, agrees
    '''
    First case - 'M'
    Second case - 'I'
    Third case - 'S'
    Fourth case - 'D'
    '''
    CigarChar = CigarOpToCigarChar(cigarOp)
    try:
        quals = rec.opt("PV")
    except KeyError:
        pl("Watch out - PV tag not set.", level=logging.DEBUG)
        quals = rec.query_qualities
        # Let's make sure that these don't need reversal, too!
    try:
        agrees = rec.opt("FA")
    except KeyError:
        pl("Watch out - FA tag not set.", level=logging.DEBUG)
        agrees = array('i', [1] * len(rec.sequence))
    return [LayoutPos(pos=x1, readPos=x0, operation=77,
                      base=ord(rec.seq[x0]), quality=quals[x0],
                      agreement=agrees[x0]) if
            x1 is not None and x0 is not None else
            LayoutPos(-1, x0, operation=CigarChar,
                      base=ord(rec.seq[x0]),
                      quality=quals[x0], agreement=agrees[x0]) if
            x0 is not None else
            LayoutPos(x1, x0, operation=83,  # 83 == "S"
                      base=ord(rec.seq[x0]),
                      quality=quals[x0], agreement=agrees[x0]) if
            CigarChar == 83 else
            LayoutPos(x1, -1, operation=68,
                      base=68,  # Base set to "D"
                      quality=-1, agreement=-1)
            for x0, x1 in rec.aligned_pairs[offset:offset + cigarLen]]


cpdef cystr MPA2stdout(cystr inBAM):
    """
    :param inBAM - path to input bam. Set to "stdin"
    :param tmpFileName - must be provided to facilitate merging streams.
    """
    from sys import stdout, stderr
    cdef size_t read_count = 0
    cdef size_t read_pair_count = 0
    cdef size_t success_merged_count = 0
    cdef size_t failed_to_merge_count = 0
    cdef AlignedSegment_t read, read1, read2
    if(inBAM == "stdin" or inBAM == "-"):
        stderr.write("Executing MPA2tmpfile, reading from stdin.\n")
        inHandle = AlignmentFile('-', 'rb')
    else:
        stderr.write("Executing MPA2tmpfile for input bam %s.\n" % inBAM)
        inHandle = AlignmentFile(inBAM, "rb")

    stdout.write(inHandle.text)  # Since pysam seems to not be able to...
    stdout.flush()
    PLFR = PyLayout.fromread
    for read in inHandle:
        read_count += 1
        if(read.is_secondary or
           read.is_supplementary or not read.is_proper_pair):
            stdout.write(read.tostring(inHandle))
            # stderr.write("Reads is supp/secondary/or improper pair!")
            continue
        if(read.is_read1):
            read1 = read
            continue
        if(read.is_read2):
            read2 = read
        read_pair_count += 1
        if(ReadsOverlap(read1, read2) is False):
            # stderr.write("Reads don't overlap... skip!")
            stdout.write(read1.tostring(inHandle))
            stdout.write(read2.tostring(inHandle))
            continue
        try:
            assert read1.qname == read2.qname
        except AssertionError:
            stderr.write("Query names %s and %s" % (read1.qname,
                                                    read2.qname) +
                         " for R1 and R2 are different. Abort!"
                         " Either this BAM isn't name-sorted or you are "
                         "missing a read from a pair.\n")
            return 1
        l1 = PLFR(read1, inHandle)
        l2 = PLFR(read2, inHandle)
        retLayout = MergeLayoutsToLayout(l1, l2)
        if(retLayout.test_merge_success()):
            success_merged_count += 1
            stdout.write(str(retLayout))
        else:
            failed_to_merge_count += 1
            stdout.write(read1.tostring(inHandle))
            stdout.write(read2.tostring(inHandle))
    inHandle.close()
    stderr.write("Processed %s pairs of reads.\n" % (read_pair_count))
    stderr.write("Successfully merged: %s\n" % (success_merged_count))
    stderr.write("Tried but failed to merge: %s\n" % (failed_to_merge_count))
    return "Success!"


cpdef MPA2Bam(cystr inBAM, cystr outBAM=None,
              bint u=False, bint coorsort=False,
              cystr sortMem="6G", bint assume_sorted=False,
              bint dry_run=False,
              cystr prepend=""):
    """
    :param inBAM - [cystr/arg] - path to input bam
    set to "-" or "stdin" to take in stdin. This must be name-sorted.
    :param outBAM - [cystr/arg] - path to output bam. Leave as default (None)
    to output to `TrimExt(inBAM) + .merged.bam` or set to stdout or '-'
    to output to stdout.
    :param u - [bint/kwarg/False] - whether or not to emit uncompressed bams.
    Set to true for piping for optimal efficiency.
    :param sortMem - [cystr/kwarg/"6G"] - string to pass to samtools sort for
    memory per thread.
    :param coorsort - [cystr/kwarg/False] - set to True to pipe to samtools
    sort instead of samtools view
    :param dry_run - [bint/kwarg/False] - set to True to returnt the command
    string rather than executing it.
    """
    cdef cystr uuidvar, tfname
    cdef bint nso
    import warnings
    from sys import stderr
    uuidvar = str(uuid.uuid4().get_hex().upper()[0:8])
    stderr.write("Now calling MPA2Bam. Emit uncompressed BAM? - %s\n" % u)
    if(inBAM == "stdin" or inBAM == "-"):
        inBAM = "-"
        pl("Now calling MPA2Bam, taking input from stdin.")
        try:
            if(assume_sorted):
                raise AbortMission("Skip this.")
            tmp = AlignmentFile(
                inBAM, "rb")
            nso = (tmp.header['HD']['SO'] == 'queryname')
            tmp.close()
        except KeyError:
            warnings.warn("Note: No SO/HD field in the bam header. "
                          "Assume namesorted, as that is default, and"
                          " sort commands usually change that field "
                          "in the header.\n")
            nso = True
        except AbortMission:
            nso = True
        stderr.write("Okay, I got out of this loop.")
    else:
        try:
            if(assume_sorted):
                raise AbortMission("Skip this.")
            tmp = AlignmentFile(
                inBAM, "rb")
            nso = (tmp.header['HD']['SO'] == 'queryname')
            tmp.close()
        except KeyError:
            warnings.warn("Note: No SO/HD field in the bam header. "
                          "Assume namesorted, as that is default, and"
                          " sort commands usually change that field "
                          "in the header.\n")
            nso = True
        except AbortMission:
            nso = True
    if(nso is False):
        if not assume_sorted:
            stderr.write("Input bam is sorted by coordinate, "
                         "not queryname. Abort!")
            sys.exit(1)
        else:
            stderr.write("Sort order unset or set to coordinate. "
                         "Assuming sorted.")
    stderr.write("Hey, let's see if testing the stream was the problem.")
    cStr = ("python -c 'import sys;from bmfutil.MPA import MPA2stdout;"
            "sys.exit(MPA2stdout(\"%s\"));'" % inBAM)
    if(coorsort is False):
        if(u):
            cStr += "| samtools view -Sbhu - "
        else:
            cStr += "| samtools view -Sbh - "

    else:
        compStr = " -l 0 " if(u) else ""
        cStr += "| samtools sort -m %s -O bam -T %s %s - " % (sortMem,
                                                              uuidvar,
                                                              compStr)
    if(outBAM == "stdout" or outBAM == "-"):
        pl("Emitting to stdout.")
        if(dry_run):
            return cStr
        check_call(cStr, shell=True)
        return outBAM
    elif(outBAM is None):
        outBAM = TrimExt(inBAM) + ".merged.bam"
    else:
        pass
    stderr.write("Command string to pass mpa output to bam format:"
                 " %s\n" % cStr)
    stderr.write("Writing to file (user-specified): '%s'\n" % outBAM)
    cStr += " > %s" % outBAM
    cStr = prepend + cStr
    if(dry_run):
        return cStr
    check_call(cStr, shell=True, executable="/bin/bash")
    return outBAM

