"""
Contains a set of utilities for evaluating uniqueness of both
mappability and capture. Also might have applications in assembly-based
variant-calling.
"""
import cython
import pysam
import uuid
import logging
from subprocess import check_output, check_call, Popen, PIPE
from bmfutil.HTSUtils import (printlog as pl, ParseBed,
                              hamming_cousins, RevCmp)
from bmfutil import HTSUtils
from bmfutil.ErrorHandling import (ThisIsMadness, ConsideredHarmful,
                                   ThisIsHKMadness)
from cytoolz import frequencies as cyfreq
from itertools import chain, groupby
from functools import partial
from operator import attrgetter, itemgetter
try:
    from re2 import compile as regex_compile
except ImportError:
    from re import compile as regex_compile
# Dictionary of edit distance flags to the reference (excludes clipping)
mmDict = {i: regex_compile(r'NM:i:[0-%s]' % i) for i in xrange(200)}
oagseq = attrgetter("seq")
cfi = chain.from_iterable
hammingPt = partial(hamming_cousins, n=1)

cimport cython


cpdef cystr SequenceToFakeFq(cystr seq):
    return ("@" + seq + "\n" + seq +
            "\n+\n" + "G" * len(seq))


cpdef list GetKmersToCheck(cystr ref, int k=30, list bedline=[],
                           int padding=-1):
    """
    Gets a list of kmers which provide unique mappability
    to the region of interest.
    bedline should be the first 3 columns from a line in a bed file.
    """
    cdef int i, start, end
    cdef list kmerList, candidateKmers
    if(padding < 0):
        pl("Padding not set - defaults to kmer size.")
        padding = k
    kmerList = []
    refHandle = pysam.FastaFile(ref)
    contig, start = bedline[0], bedline[1] - padding
    end = bedline[2] + padding
    regionStr = refHandle.fetch(contig, start, end)
    return [regionStr[i:i + k] for i in xrange(end - start - k)]


cpdef cystr FastqStrFromKmerList(list kmerList):
    """
    Creates a dummy fastq string from a list of kmers.
    """
    return "\n".join(map(SequenceToFakeFq, kmerList))


cdef class RefKmer(object):
    """
    Contains useful information regarding representative kmers selected
    from reference sequence.
    :param: cystr seq
    :param: cystr contig=None
    :param: int pos=-1
    """

    def __init__(self, cystr seq, cystr contig=None,
                 int pos=-1):
        assert pos >= 0  # pos needs to be set
        self.contig = contig
        self.seq = seq
        self.len = len(seq)
        self.pos = pos

    @cython.returns(cystr)
    def __str__(self):
        return "%s|%s|%s" % (self.contig, self.pos, self.seq)

    cpdef int getSeqLen(self):
        return len(self.seq)


cdef class KmerFetcher(object):
    """Contains parameters for finding representative kmers.
    I want to permit the mixing of kmers of different sizes, so I have
    set a baseK, which is the K that we start using.

    minMQ defaults to 1, meaning a unique mapping for most aligners.
    Bowtie instead uses 255 to refer to unique alignments and (0,3) to mark
    multiple acceptable alignments.

    TODO: I'd like to have it know where dropout regions for these kmers
    are and have it increase the size of k only as necessary... Not sure
    how to automate that.

    :param cystr ref - path to reference fasta file.
    :param int padding - distance around region to pad for
           looking for kmers
    :param int mismatches - maximum permitted mismatches in alignment.
    Defaults to 0.
    :param int minMQ - minimum MQ for a kmer's alignment to be
    considered acceptable.
    Defaults to 1
    :param int k - length of kmers;
    * Note: minMQ doesn't make sense with bowtie/bowtie2's mapping quality
    assignments.
    Example use for creating a mapper with this:

    KF = KmerFetcher(ref="/home/daniel/human_g1k_v37.fasta", k=32)
    mapper = KF.BedToMap("~/cfDNA_targets.bed")

    Now you can map reads with this mapper!

    Alternatively, you can use KF.IBedToMap("~/cfDNA_targets.bed").
    Instead of assigning that hashmap to mapper as above, the hashmap
    is saved as self.FullMap.

    """
    def __init__(self, cystr ref=None, int padding=50,
                 int mismatches=0, int minMQ=1,
                 int k=30, int seed=-1, cystr aligner='mem'):
        self.ref = ref
        if(mismatches >= 0):
            self.mismatches = mismatches
        else:
            pl("KmerFetcher's mismatches set to below 0 - setting to 0, "
               "as that breaks downstream steps.")
            self.mismatches = 0
        self.minMQ = minMQ
        self.padding = padding
        self.k = k
        self.seed = seed
        self.aligner = aligner
        self.HashMap = {}
        self.FullMap = None

    def IBedToMap(self, cystr bedpath):
        """Fills the HashMap for each line in the bed file.
        Sets the FullMap hashmap to map all strings within hamming distance
        of mismatches limit.
        I is for in-place.
        """
        cdef list bedline
        cdef list bedlines = HTSUtils.ParseBed(bedpath)
        for bedline in bedlines:
            bedline[1] -= self.padding
            bedline[2] += self.padding
            self.FillMap(bedline)
        self.FullMap = self.BuildMapper(maplimit=self.mismatches)

    @cython.returns(dict)
    def BedToMap(self, cystr bedpath):
        """Fills the HashMap for each line in the bed file.
        Returns a hashmap which maps all strings within hamming distance
        of mismatches limit.
        """
        self.IBedToMap()
        return self.FullMap
    # Should we consider changing the number of mapping mismatches permitted
    # so as to be more stringent than with our mappability analysis?

    cdef setK(self, int newK):
        """Sets the value of K to the argument.
        """
        self.k = newK

    cdef int getK(self):
        return self.k

    cpdef cystr getFastqString(self, list bedline):
        return FastqStrFromKmerList(GetKmersToCheck(self.ref, k=self.k,
                                                    bedline=bedline,
                                                    padding=0))

    cpdef cystr getOutputString(self, list bedline, cystr aligner="mem"):
        if(aligner == "mem"):
            return BwaFqToStr(self.getFastqString(bedline), ref=self.ref)
        elif(aligner == "bwt"):
            raise ConsideredHarmful("Use of bowtie for uniqueness"
                                    " calculations is unreliable.")
            return BowtieFqToStr(self.getFastqString(bedline), ref=self.ref,
                                 seed=self.seed, mismatches=self.mismatches)
        else:
            raise NotImplementedError("Sorry, only bwa mem and bowtie"
                                      " are supported currently.")

    cpdef FillMap(self, list bedline):
        """Fills a dictionary (keyed by the input bed file 'chr:start:stop')
        with the list of kmers in that region that map uniquely
        to the reference.
        """
        self.HashMap[
            ":".join(map(str, bedline))] = self.GetUniqueKmers(bedline)

    @cython.returns(list)
    def GetIntervalsFromMap(self):
        """
        Converts a dictionary (keyed by the input bed file 'chr:start:stop') of
        list of kmer objects into a list of continuous intervals of kmer start
        positions.
        """
        cdef list intervalList, bedRegionKmerList
        cdef cython.str key, contig
        cdef RefKmer kmObj
        # Convert list of Kmers to list of continuous starting positions (kmers
        # all the same length)
        intervalList = []
        keyList = self.HashMap.keys()
        for key in self.HashMap.iterkeys():
            bedRegionKmerList = self.HashMap[key]
            if len(set([kmObj.contig for kmObj in
                   bedRegionKmerList])) not in [0, 1]:
                raise ThisIsHKMadness("Contigs do not match in this bed "
                                      "region, aborting.")
            else:
                try:
                    contig = bedRegionKmerList[0].contig
                except IndexError:
                    # No passing kmers. Ignore!
                    continue
            # Finds continuous passing positions
            for k, g in groupby(enumerate([kmObj.pos for kmObj in
                                           bedRegionKmerList]), lambda x: x[0]-x[1]):
                group = list(g)
                intervalList.append((contig, group[0][1], group[-1][1]))
        return sorted(intervalList)

    def GetCoverableIntervals(self):
        tmpbed = [[j[0], j[1], j[2] + self.k] for
                  j in self.GetIntervalsFromMap()]
        if(len(tmpbed) <= 1):
            return tmpbed
        for i in xrange(len(tmpbed) - 2, -1, -1):
            if tmpbed[i][0] != tmpbed[i + 1][0]:
                continue
            if tmpbed[i][2] >= tmpbed[i + 1][1]:
                tmpbed[i][2] = tmpbed[i + 1][2]
                del tmpbed[i + 1]
        return tmpbed

    def WriteIvlsToBed(self, outpath):
        open(outpath, "w").write("\n".join(["\t".join(map(str, ivl)) for
                                            ivl in self.GetIntervalsFromMap()]))

    def WriteCoverableIntervalBedFiles(self, bedpath):
        for kmer in xrange(20, 122, 2):
            self.k = kmer
            self.IBedToMap(bedpath)
            self.WriteIvlsToBed("%s.Unique%i-mers.bed" % (bedpath, kmer))

    cpdef ConvertIntervalsToBed(self, list intervalList, cystr inFile,
                                cystr outFile, bint startsOnly=False):
        """
        Converts a list of continuous intervals of kmer start positions
        (output from GetIntervalsFromMap is (contig,
        continuousStartIntervalFirst, continuousStartIntervalLast)
        to a bed file (outFile) with a left open intervals, e.g. (start, stop].
        Output will return a bed file of starts if startsOnly=True, otherwise
        returns a bed file of full intervals incorporating the kmer size.
        """
        pl("Creating bed file describing regions with unique kmer mappings.")
        kmer = self.k
        if startsOnly:
            bedStrList = ["%s\t%s\t%s\n" % (contig, startFirst-1, startLast)
                          for (contig, startFirst, startLast) in intervalList]
        else:
            bedStrList = ["%s\t%s\t%s\n" % (contig, startFirst-1,
                                            startLast + kmer - 1)
                          for (contig, startFirst, startLast) in intervalList]
        # Sort and Merge bed file
        pl("Sorting and merging output bed file with bedtools.")
        echo = Popen(['echo', "".join(bedStrList)], stdout=PIPE)
        sort = Popen(['sort', '-k1,1n', '-k2,2n', '-V', '-'], stdin=echo.stdout,
                        stdout=PIPE)
        merge = Popen(['bedtools', 'merge', '-i', '-'], stdin=sort.stdout,
                      stdout=PIPE)
        intersect = Popen(['bedtools', 'intersect', '-a', inFile, '-b', '-'],
                          stdin=merge.stdout, stdout=PIPE)
        sortagain = Popen(['sort', '-k1,1n', '-k2,2n', '-V', '-'], stdin=intersect.stdout,
                        stdout=PIPE)
        output = ''.join(list(sortagain.communicate()[0]))
        with open(outFile, 'w') as f:
            f.write(output)
        if startsOnly:
            logStr = "unique kmer starts"
        else:
            logStr = "unique kmer full intervals"
        pl("Final sorted merged/intersected bed file covering " + logStr +
           " built for kmers of size " + str(kmer) + " saved to " + outFile)

    cpdef list GetUniqueKmers(self, list bedline):
        output = self.getOutputString(bedline, aligner=self.aligner)
        return GetMQPassRefKmersMem(output,
                                    maxNM=self.mismatches, minMQ=self.minMQ)

    cpdef FMfrombed(self, cystr bedfile):
        cdef list bedline
        for bedline in ParseBed(bedfile):
            self.FillMap(bedline)

    def __getitem__(self, key):
        return self.HashMap[key]

    def iteritems(self, *args, **kwargs):
        return self.HashMap.iteritems(*args, **kwargs)

    def items(self, *args, **kwargs):
        return self.HashMap.items(*args, **kwargs)

    def itervalues(self, *args, **kwargs):
        return self.HashMap.itervalues(*args, **kwargs)

    def values(self, *args, **kwargs):
        return self.HashMap.values(*args, **kwargs)

    def iterkeys(self, *args, **kwargs):
        return self.HashMap.iterkeys(*args, **kwargs)

    def keys(self, *args, **kwargs):
        return self.HashMap.keys(*args, **kwargs)

    @cython.returns(dict)
    def BuildMapper(self, object cfi=cfi, int maplimit=1,
                    object oagseq=oagseq, object hammingPt=hammingPt,
                    object RevCmp=RevCmp):
        """
        Once all regions of interest have been build,
        create the mapping dictionary.
        :param cfi - localizes the chain.from_iterable call.
        :param hammingPt - localizes a partial hamming distance.
        """
        cdef cystr region, kmer
        cdef list kmerlist, mappingTups
        cdef dict mappingDict
        mappingTups = []
        for region, kmerlist in self.iteritems():
            mappingTups += [(kmer, region) for
                            kmer in list(cfi(map(hammingPt,
                                                 map(oagseq, kmerlist))))]
        return dict(mappingTups + [(RevCmp(kmer), region) for
                                   kmer, region in mappingTups])


'''
@cython.returns(dict)
def GetRepresentativeKmerDict(*args, **kwargs):
    return cyfreq(GetRepKmersBwt(*args, **kwargs))

cpdef list GetRepKmersBwt(cystr ref, int k=30,
                          list bedline=[],
                          int padding=-1, int seedlen=-1,
                          int mismatches=-1, int minMQ=1,
                          bint useBowtie=False):
    cdef cystr fqStr, output
    fqStr = FastqStrFromKmerList(GetKmersToCheck(ref, k=k, bedline=bedline,
                                                 padding=padding))
    if(useBowtie):
        raise NotImplementedError("Something's weird with bowtie output.")
    else:
        output = BwaFqToStr(fqStr, ref=ref, seed=seedlen)
    return GetUniqMQsBowtie(output, minMQ=minMQ)
'''

cpdef cystr BowtieFqToStr(cystr fqStr, cystr ref=None,
                          int seed=-1, int mismatches=-1):
    """
    Returns the string output of a bowtie2 call.
    With bowtie, you can specify precisely the number of permitted mismatches
    in the string, but with bowtie2, you don't need to write any temporary
    files. I'll play around with the alignment settings as I get along in
    the getkmers tool.
    """
    if(seed < 0):
        raise ThisIsMadness("seed length must be set for Bowtie2FqToStr.")
    if(mismatches > 2 or mismatches < 0):
        raise ThisIsMadness("0 <= mismatches <= 2!")
    tmpFile = str(uuid.uuid4().get_hex()[0:8]) + ".hey.i.am.a.prefix.fq"
    tmpFileHandle = open(tmpFile, "w")
    tmpFileHandle.write(fqStr)
    tmpFileHandle.close()
    cStr = "bowtie --mm --all -n %s -l %s %s -S %s" % (mismatches, seed,
                                                       ref, tmpFile)
    pl("Bowtie command string: %s" % cStr, level=logging.DEBUG)
    print("Bowtie command string: %s" % cStr)
    outStr = check_output(cStr, shell=True)  # Capture output to string
    check_call(["rm", tmpFile])  # Delete the temporary file.
    print("Returning bowtieFqToStr output")
    return outStr


@cython.returns(cystr)
def BwaFqToStr(cystr fqStr, cystr ref=None,
               int seed=-1):
    """
    Returns the string output of a bwa mem call.
    """
    cdef cystr seedStr, cStr, outStr, tmpFile
    tmpFile = str(uuid.uuid4().get_hex()[0:8]) + ".hey.i.am.a.prefix.fq"
    tmpFileHandle = open(tmpFile, "w")
    tmpFileHandle.write(fqStr)
    tmpFileHandle.close()
    if(seed > 0):
        seedStr = "-k %s" % seed
    else:
        seedStr = ""
    cStr = "bwa mem -a %s %s %s" % (ref, seedStr, tmpFile)
    pl("Bwa command string: %s" % cStr, level=logging.DEBUG)
    print("Bwa command string: %s" % cStr)
    outStr = check_output(cStr, shell=True)  # Capture output to string
    check_call(["rm", tmpFile])  # Delete the temporary file.
    pl("Returning BwaFqToStr output with %s lines" % outStr.count("\n"),
       level=logging.INFO)
    return outStr


@cython.returns(bint)
def PassesNM(cystr rStr, int maxNM=2, dict mmDict=mmDict):
    """
    Checks a SAM line to see if its edit distance is below or equal
    to the maximum.
    """
    return mmDict[maxNM].search(rStr) is not None


@cython.returns(list)
def GetMQPassRefKmersMem(cystr bwaStr, int maxNM=2, int minMQ=1):
    """
    Takes a string output from bowtie (SAM format) and gets the names of the
    reads with MQ >= minMQ that are unique alignments. Returns a list of
    RefKmer objects built from passing bowtie output with unique mappings
    (no XA:Z or XT:A:R flags or
    non-zero mapping qualities).
    """
    cdef list lines, i
    cdef cystr f
    cdef tuple nameCount
    pl("Number of reads is (approximately) " +
       str(bwaStr.count("\n") - bwaStr.count("@")), level=logging.DEBUG)

    return [RefKmer(i[0], contig=i[2],
                    pos=int(i[3])) for i in [f.strip().split("\t") for
                                             f in bwaStr.split("\n") if
                                             "XA:Z:" not in f and  # Supp aln
                                             "XT:A:R" not in f and  # Supp aln
                                             f != "" and  # Empty line
                                             f[0] != "@" and  # Header
                                             PassesNM(f, maxNM=maxNM)]  # NM
            if i[4] != "0" and i[4] >= minMQ]


@cython.returns(list)
def GetMQPassReadsMem(cystr bwaStr):
    """
    Takes a string output from bowtie and gets the names of the reads
    with MQ >= minMQ. Defaults to 1 (for a unique alignment)
    """
    cdef list i
    cdef cystr f
    return [i[0] for i in [f.strip().split("\t") for
                           f in bwaStr.split("\n") if f != "" and
                           f[0] != "@" and "XA:Z:" not in f]
            if i[4] != "0"]


@cython.returns(list)
def GetMQPassRefKmersBwt1(cystr bwtStr):
    """
    Takes a string output from bowtie and gets the names of the reads
    with MQ >= minMQ. Defaults to 1 (for a unique alignment)
    """
    cdef list lines, i
    cdef cystr f
    cdef tuple nameCount
    return [RefKmer(i[0], contig=i[2], pos=int(i[3])) for
            i in [f.strip().split("\t") for
                  f in bwtStr.split("\n") if
                  f != "" and f[0] != "@"]
            if i[4] == "255"]


@cython.returns(list)
def GetMQPassReadsBwt1(cystr bwtStr):
    """
    Takes a string output from bowtie and gets the names of the reads
    with MQ >= minMQ. Defaults to 1 (for a unique alignment)
    """
    cdef list lines, i
    cdef cystr f
    cdef tuple nameCount
    return [i[0] for i in [f.strip().split("\t") for
                           f in bwtStr.split("\n") if
                           f != "" and f[0] != "@"]
            if i[4] == "255"]
