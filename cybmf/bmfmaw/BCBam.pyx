# cython: c_string_type=str, c_string_encoding=ascii
# cython: boundscheck=False
import shlex
import subprocess
import os
import shutil
import logging
from copy import copy as ccopy
from os import path
import operator
from operator import attrgetter as oag, methodcaller as mc
import string
import uuid
import sys
from subprocess import check_call
from functools import partial
from itertools import groupby, chain
from array import array

import numpy as np
from numpy import (sum as nsum, multiply as nmul,
                   subtract as nsub, argmax as nargmax,
                   vstack as nvstack, char)
from cytoolz import frequencies as cyfreq
import pysam
import cython

from .BCFastq import GetDescriptionTagDict as getdesc, fqmarksplit_dmp
from . import BCFastq
from bmfutil.HTSUtils import *
from bmfutil.HTSUtils import printlog as pl
from bmfutil.ErrorHandling import (IllegalArgumentError, ThisIsMadness as Tim,
                                   MissingExternalTool)
from bmfutil import HTSUtils
from warnings import warn
import bmfsecc

cdef int DEFAULT_MMLIM = 2


def AbraCadabra(inBAM, outBAM="default",
                jar="default", sortMem="default", ref="default",
                threads="4", bed="default", working="default",
                log="default", bint fixMate=True, tempPrefix="tmpPref",
                rLen=-1, intelPath="default", bint leftAlign=True,
                bint kmers_precomputed=True):
    """
    Calls abra for indel realignment. It supposedly
    out-performs GATK's IndelRealigner, though it does right-align
    some indels.

    It also calls samtools fixmate to restore mate information and
    bamleftalign to left align any that abra right-aligned.
    """
    if(rLen < 0):
        raise IllegalArgumentError("Read length must be set to call abra due"
                                   " to the benefits of inferring ideal para"
                                   "meters from the !")
    if(jar == "default"):
        raise MissingExternalTool("Required: Path to abra jar!")
    else:
        pl("Non-default abra jar used: " + jar)
    if(sortMem == "default"):
        sortMem = "-Xmx16G"
        pl("Default memory string used: " + sortMem)
    else:
        pl("Non-default memory string used: " + sortMem)
    if(ref == "default"):
        raise ValueError("Reference fasta must be provided!")
    if(ref.split(".")[-1] == "gz"):
        warn("Reference fasta is gzipped, with which "
             "abra is not compatible. Be warned!", UserWarning)
    else:
        pl("Reference file set: {}.".format(ref))
    if(bed == "default"):
        raise ValueError("Bed file required.")
    else:
        pl("Bed file set: {}.".format(bed))
    if(working == "default"):
        bamFilename = path.basename(inBAM)
        working = (path.dirname(inBAM) + bamFilename.split('.')[0] +
                   ".working_dir")
        pl("Default working directory set to be: " + working)
    else:
        pl("Non-default working directory: " + working)
    if(log == "default"):
        log = "abra.log"
    if(outBAM == "default"):
        outBAM = '.'.join(inBAM.split('.')[0:-1]) + '.abra.bam'
    pl(("Command to reproduce the call of this function: "
        "AbraCadabra(\"{}\", outBAM=\"{}\", jar=\"{}\", ".format(inBAM,
                                                                 outBAM,
                                                                 jar) +
        "sortMem=\"{}\", ref=\"{}\", threads=\"{}\", ".format(sortMem,
                                                              ref, threads) +
        "bed=\"{}\", working=\"{}\", log=\"{}\")".format(bed, working, log)))
    if(path.isdir(working)):
        pl("Working directory already exists - deleting!")
        shutil.rmtree(working)
    # Check bed file to make sure it is in appropriate format for abra
    if(kmers_precomputed is False):
        bed = AbraKmerBedfile(bed, ref=ref, abra=jar,
                              rLen=rLen)
    if(path.isfile(inBAM + ".bai") is False):
        pl("No bam index found for input bam - attempting to create.")
        check_call(['samtools', 'index', inBAM])
        if(path.isfile(inBAM + ".bai") is False):
            inBAM = HTSUtils.CoorSortAndIndexBam(inBAM, outBAM, uuid=True)
    command = ("java {} -jar {} --in {}".format(sortMem, jar, inBAM) +
               " --out {} --ref {} --targets".format(outBAM, ref) +
               " {} --threads {} ".format(bed, threads) +
               "--working %s --mbq 200 --mer 0.0025 --mad 20000" % working)
    if(kmers_precomputed):
        command = command.replace("--targets", "--target-kmers")
    pl("Command: {}.".format(command))
    check_call(shlex.split(command), shell=False)
    pl("Deleting abra's intermediate directory.")
    check_call(["rm", "-rf", working])
    if(fixMate):
        pl("Now fixing mates after abra's realignment.")
        tempFilename = tempPrefix + str(
            uuid.uuid4().get_hex()[0:8]) + ".working.tmp"
        nameSorted = HTSUtils.NameSort(outBAM)
        commandStrFM = "samtools fixmate %s %s -O bam" % (nameSorted,
                                                          tempFilename)
        check_call(shlex.split(commandStrFM))
        check_call(["rm", "-rf", nameSorted])
        check_call(["mv", tempFilename, outBAM])
    if(leftAlign):
        # Calls bamleft align to make sure things are fixed up.
        tmpfile = str(uuid.uuid4().get_hex()[0:8]) + '.bam'
        cStr = ("samtools view -ubh %s | bamleftalign -f " % (outBAM) +
                "%s -c > %s && mv %s %s" % (ref, tmpfile, tmpfile, outBAM))
        check_call(cStr, shell=True)
    return outBAM


@cython.locals(rLen=int)
def AbraKmerBedfile(inbed, rLen=-1, ref="default", outbed="default",
                    nt=4, abra="default"):
    if(abra == "default"):
        raise MissingExternalTool(
            "Path to abra jar required for running KmerSizeCalculator.")
    if(ref == "default"):
        raise Tim(
            "Path to reference required for running KmerSizeCalculator.")
    if(inbed == "default"):
        raise Tim(
            "Path to input bed required for running KmerSizeCalculator.")
    if(rLen < 0):
        raise Tim(
            "Read length required for running KmerSizeCalculator.")
    if(outbed == "default"):
        outbed = ".".join(inbed.split(".")[0:-1] + ["abra", "kmer"])
    commandStr = ("java -cp %s abra.KmerSizeEvaluator " % abra +
                  "%s %s %s %s %s" % (rLen, ref, outbed, nt, inbed))
    pl("AbraKmerSizeEvaluator call string: %s" % commandStr)
    check_call(commandStr, shell=True)
    return outbed


cpdef cystr fqms_dmp_align_rescue(cystr Fq1, cystr Fq2, cystr indexFq,
                                  outBAM=None, ref=None, rescaler_path=None,
                                  tmp_basename="", ffq_basename="",
                                  int hpThreshold=-1, int n_nucs=-1,
                                  int salt=-1, int offset=-1, int dmp_ncpus=-1,
                                  bwa_opts=None, tmpbam_prefix=None, memStr=None,
                                  int mmlim=DEFAULT_MMLIM, cleanup=True,
                                  int br_ncpus=-1, path=None):
    """
    :param: Fq1 - [cystr/arg] - path to input fastq for read 1
    :param: Fq2 - [cystr/arg] - path to input fastq for read 2
    :param: indexFq [cystr/arg]
    :param: outBAM - [cystr/kwarg/TrimExt(Fq1) + ".bmf.rsq.bam"] -
    path for final output BAM
    :param: ref [object/kwarg/None] path to reference index base
    :param: rescaler_path [object/kwarg/None] path to rescaler flat text file
    for bootstrapping from the sequencer/chemistry/run. If not None,
    the file will be parsed. Otherwise, it won't be used.
    :param: tmp_basename [object/kwarg/""] - Defaults to variation on input.
    :param: ffq_basename [object/kwarg/""] - Defaults to variation on input.
    :param: hpThreshold [int/kwarg/12] - Maximum homopolymer length
    permitted for QC pass in barcode.
    :param: n_nucs [int/kwarg/4] - Number of nucleotides at the start of the
    barcode by which to split the marked fastqs.
    :param: salt [int/kwarg/1] - Number of bases from the start of each read
    to use to "salt" the molecular barcode.
    :param: offset [int/kwarg/1] - Number of bases at the start of each read
    when salting the barcode. -m parameter for fqmarksplit.
    :param: dmp_ncpus - [int/kwarg/4]
    :param: br_ncpus - [int/kwarg/4]
    :param: path - [cystr/kwarg/"default"] - absolute path to bwa executable.
    Defaults to 'bwa'
    :param: bwa_opts - [cystr/kwarg/"-t <threads> -v 1 -Y -T 0"] - opt arguments
    to provide to bwa for alignment.
    :param: memStr - [cystr/kwarg/"6G"]
    :param: path - [object/kwarg/None] - Path to bwa executable.
    :param: mmlim [int/kwarg/2] - Mismatch limit for rescue step.
    :param: cleanup - [bint/kwarg/True] - Clean up temporary files.
    :returns: [cystr] - Path to final BAM file
    """
    dmp_fq1, dmp_fq2 = fqmarksplit_dmp(Fq1, Fq2, indexFq,
                                       tmp_basename=tmp_basename,
                                       ffq_basename=ffq_basename,
                                       rescaler_path=rescaler_path,
                                       hpThreshold=hpThreshold, n_nucs=n_nucs,
                                       offset=offset, salt=salt,
                                       dmp_ncpus=dmp_ncpus)
    if(not outBAM):
        outBAM = TrimExt(Fq1) + ".bmfrsq.bam"
    bmf_align_rescue(dmp_fq1, dmp_fq2, outBAM, ref=ref, opts=bwa_opts,
                     prefix=tmpbam_prefix, memStr=memStr, mmlim=mmlim,
                     cleanup=cleanup, br_ncpus=br_ncpus, path=path)
    return outBAM


cpdef cystr bmf_align_rescue(cystr R1, cystr R2, cystr outBAM, cystr ref=None,
                             cystr opts=None, cystr path=None,
                             int threads=4, prefix=None, memStr=None,
                             int mmlim=DEFAULT_MMLIM, bint cleanup=True,
                             int br_ncpus=-1):
    """
    :param: R1 - [cystr/arg] - path to input fastq for read 1
    :param: R2 - [cystr/arg] - path to input fastq for read 2
    :param: outBAM - [cystr/arg] - path for final output BAM
    :param: ref [cystr/kwarg/None] path to reference index base
    :param: path - [cystr/kwarg/"default"] - absolute path to bwa executable.
    Defaults to 'bwa'
    :param: sortMem - [cystr/kwarg/"6G"] - sort memory limit for samtools
    :param: opts - [cystr/kwarg/"-t <threads> -v 1 -Y -T 0"] - opt arguments
    to provide to bwa for alignment.
    :param: br_ncpus - [int/kwarg/8]
    :param: memStr - [cystr/kwarg/"6G"]
    :param: cleanup [bint/kwarg/True]
    :returns: [cystr] - Path to final BAM file
    """
    if  not memStr:
        memStr="6G"
    cdef list bampaths
    cdef cystr ret
    if not ref:
        raise ValueError("Reference path required for an alignment!")
    if(br_ncpus < 0):
        br_ncpus = 4
        sys.stderr.write("Note: br_ncpus unset. "
                         "Setting to default (%i).\n" % br_ncpus)
    bampaths = bmf_align_split(R1, R2, ref=ref, opts=opts,
                               path=path, threads=threads,
                               prefix=prefix, memStr=memStr)
    return rescue_bam_list(outBAM, bampaths, ref=ref,
                           opts=opts, mmlim=mmlim,
                           threads=4, cleanup=False)


cpdef list bmf_align_split(R1, R2, ref=None,
                           opts=None, path=None,
                           int threads=8, prefix=None, memStr="6G"):
    """
    :param: R1 - [cystr/arg] - path to input fastq for read 1
    :param: R2 - [cystr/arg] - path to input fastq for read 2
    :param: ref [cystr/kwarg/"default"] path to reference index base
    :param: path - [cystr/kwarg/"default"] - absolute path to bwa executable.
    Defaults to 'bwa'
    :param: sortMem - [cystr/kwarg/"6G"] - sort memory limit for samtools
    :param: opts - [cystr/kwarg/"-t <threads> -v 1 -Y -T 0"] - opt arguments
    to provide to bwa for alignment.
    :param: dry_run - [bint/kwarg/False] - flag to return the command string
    rather than calling it.
    :param: threads - [int/kwarg/8]
    :param: memStr - [cystr/memStr/"6G"]
    :returns: [list] - List of strings of output bam files.
    """
    if not path:
        path = "bwa"
    if not opts:
        opts = "-t %i -v 1 -Y " % threads
    split_opts = opts.split()
    for n, opt in enumerate(split_opts):
        if(opt == "-t"):
            split_opts[n + 1] = str(threads)
    if not prefix:
        prefix = TrimExt(R1)
    opt_concat = ' '.join(opts.split())
    cStr = "%s mem -C %s %s %s %s " % (path, opt_concat, ref, R1, R2)
    cStr += " | bmfsort -sp %s -m %s" % (prefix, memStr)
    sys.stderr.write("Command string for bmf align split: %s.\n" % cStr)
    check_call(cStr, shell=True, executable="/bin/bash")
    outfnames = ["%s.%s.bam" % (prefix, contig) for contig in
                 pysam.FastaFile(ref).references]
    return outfnames


def catfq_sort_str(cystr fq):
    return "cat %s | paste -d'~' - - - - | sort -k1,1 | tr '~' '\n' " % fq


cdef int has_records(cystr bampath):
    a = pysam.AlignmentFile(bampath, "rb")
    try:
        b = a.next()
        return 1
    except StopIteration:
        return 0


cpdef cystr rescue_bam_list(cystr outBAM, list fnames, cystr ref=None,
                            cystr opts=None, int mmlim=DEFAULT_MMLIM,
                            int threads=4, bint cleanup=False, int br_ncpus=1,
                            int merge_threads=2):
    import multiprocessing as mp
    pool = mp.Pool(processes=br_ncpus)
    cdef cystr random_prefix = str(uuid.uuid4().get_hex()[0:8])
    cdef cystr prefix = TrimExt(outBAM)
    cdef list fqs = []
    cdef uint64_t nonzero_lines = 0
    assert ref is not None
    if not opts:
        opts = "-t 4 -v 1 -Y "
    tuple_set = [(tmp, TrimExt(tmp) + ".tmprsq.bam",
                  TrimExt(tmp) + ".tmprsq.fq") for tmp in fnames
                 if has_records(tmp)]
    [check_call(["rm", tmp]) for tmp in fnames if has_records(tmp) is False]
    if br_ncpus > 1:
        pl("Now doing bam rescue on each sub bam "
           "in parallel with %i cpus." % br_ncpus)
        fqs = [pool.apply_async(pBamRescue, args=(tup[0], tup[1], tup[2]),
                                kwds={"mmlim": mmlim}) for tup in tuple_set]
    else:
        pl("Now doing bam rescue in series.")
        fqs = [BamRescue(tup[0], tup[1], tup[2], mmlim=mmlim) for
               tup in tuple_set]
    tmpbams = [tup[1] for tup in tuple_set]
    # Empty bams and fastqs need to be axed.
    files_to_del = [tup for tup in tuple_set if
                    os.path.isfile(tup[1]) is False]
    [check_output(["rm", fn], shell=True) for fn in list(cfi(files_to_del))]
    tuple_set = [tup for tup in tuple_set if os.path.isfile(tup[1])]

    if cleanup:
        check_call("rm %s" % " ".join([tup[0] for tup in tuple_set]))
    pl("Now catting fastqs together to align and merge "
       "back into the final bam.")
    # Check to see if they're all empty (a rare occurrence)
    for fq in fqs:
        print("Looking for fastq %s." % fq)
        if(int(check_output("head %s | wc -l" % fq,
                            shell=True).split()[0]) > 0):
            nonzero_lines = 1
            break
    if nonzero_lines != 0:
        cStr = "cat %s" % (" ".join(fqs))
        cStr += " | paste -d'~' - - - - | sort -k1,1 | tr '~' '\n'"
        cStr += " | bwa mem -C -p %s %s - | samtools sort" % (opts, ref)
        cStr += " -O bam -l 0 -T %s - | samtools merge -f " % (random_prefix)
        cStr += "-@ %s %s %s" % (merge_threads, outBAM, " ".join(tmpbams))
    else:
        sys.stderr.write("Note: all fastqs were empty. "
                         "Nothing was rescued.\n")
        cStr = "samtools merge -f -@ %i %s %s" % (threads,
                                                  outBAM,
                                                  " ".join([tmp for
                                                            tmp in tmpbams]))
    pl("About to call cStr: '%s'." % cStr)
    check_call(cStr, shell=True, executable="/bin/bash")
    if cleanup:
        [check_call("rm %s %s" % (tup[1], tup[2]), shell=True) for
         tup in tuple_set]
    return outBAM


def GATKIndelRealignment(inBAM, gatk="default", ref="default",
                         bed="default", dbsnp="default"):
    if(ref == "default"):
        raise MissingExternalTool("Reference file required"
                                  " for Indel Realignment")
    if(bed == "default"):
        raise Tim("Bed file required for Indel Realignment")
    if(gatk == "default"):
        raise MissingExternalTool("Path to GATK Jar required "
                                  "for Indel Realignment")
    print dbsnp
    if(dbsnp == "default"):
        dbsnpStr = ""
        pl("Running GATK Indel Realignment without dbSNP for known indels.")
    else:
        dbsnpStr = " -known %s " % dbsnp
    out = ".".join(inBAM.split(".")[0:-1] + ["realignment", "intervals"])
    outBAM = ".".join(inBAM.split(".")[0:-1] + ["gatkIndelRealign", "bam"])
    RTCString = "".join([
        "java -jar %s -T RealignerTargetCreator" % gatk,
        " -R %s -o %s -I %s -L:intervals,BED %s" % (ref, out, inBAM, bed),
        dbsnpStr])
    pl("RealignerTargetCreator string: %s" % RTCString)
    try:
        check_call(shlex.split(RTCString))
    except subprocess.CalledProcessError:
        pl("GATK RealignerTargetCreator failed. Still finish the "
           "analysis pipeline...")
        return inBAM
    IRCString = "".join(["java -jar %s -T IndelRealigner -targetInt" % gatk,
                         "ervals %s -R %s -I %s -o %s " % (out, ref,
                                                           inBAM, outBAM),
                         dbsnpStr])
    pl("IndelRealignerCall string: %s" % IRCString)
    try:
        check_call(shlex.split(IRCString))
    except subprocess.CalledProcessError:
        pl("GATK IndelRealignment failed. Still finish the analysis pipeline.")
        return inBAM
    pl("Successful GATK indel realignment. Output: %s" % outBAM)
    return outBAM


cdef dict cGetCOTagDict(AlignedSegment_t read):
    cdef cystr s, cStr
    cStr = read.opt("CO")
    return dict([s.split("=") for s in cStr.split("|")[1:]])


cpdef dict pGetCOTagDict(AlignedSegment_t read):
    return cGetCOTagDict(read)


@cython.wraparound(False)
cdef inline char * cRPString(bam1_t * src, bam_hdr_t * hdr) nogil:
    cdef char[100] buffer
    cdef size_t length
    length = sprintf("%s:%i,%s:%i", buffer, hdr.target_name[src.core.tid],
                     src.core.pos, hdr.target_name[src.core.mtid],
                     src.core.mpos)
    return buffer


cdef class BamPipe:
    """
    Creates a callable function which acts on a BAM stream.

    :param function - callable function which returns an input BAM object.
    :param bin_input - boolean - true if input is BAM
    false for TAM/SAM
    :param bin_output - boolean - true to output in BAM format.
    :param uncompressed_output - boolean - true to output uncompressed
    BAM records.
    """
    cpdef process(self):
        cdef AlignedSegment_t read
        [self.write(self.function(read)) for read in self.inHandle]

    def __init__(self, object function, bint bin_input, bint bin_output,
                 bint uncompressed_output=False):
        if(bin_input):
            self.inHandle = pysam.AlignmentFile("-", "rb")
        else:
            self.inHandle = pysam.AlignmentFile("-", "r")
        if(bin_output):
            if(uncompressed_output):
                self.outHandle = pysam.AlignmentFile(
                    "-", "wbu", template=self.inHandle)
            else:
                self.outHandle = pysam.AlignmentFile(
                    "-", "wb", template=self.inHandle)
        assert hasattr("__call__", function)
        self.function = function

    cdef write(self, AlignedSegment_t read):
        self.outHandle.write(read)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef double getSF(AlignedSegment_t read):
    cdef tuple tup
    cdef int sum, sumSC
    sum = 0
    sumSC = 0
    if(read.cigarstring is None):
        return 0.
    for tup in read.cigar:
        sum += tup[1]
        if(tup[0] == 4):
            sumSC += tup[1]
    return sumSC * 1. / sum if(sum != 0) else 0.


@cython.boundscheck(False)
@cython.wraparound(False)
cdef double getAF(AlignedSegment_t read):
    cdef tuple tup
    cdef int sum, sumAligned
    sum = 0
    sumAligned = 0
    if(read.cigarstring is None):
        return 0.
    for tup in read.cigar:
        sum += tup[1]
        if(tup[0] == 0):
            sumAligned += tup[1]
    return sumAligned * 1. / sum


cdef inline void CompareSeqQual(int32_t * template_quality,
                                int32_t * cmp_quality,
                                int8_t * seq1, int8_t * seq2,
                                int32_t rLen) nogil:
    cdef size_t index
    for index in range(rLen):
        if(seq1[index] == seq2[index]):
            template_quality[index] = MergeAgreedQualities(
                <int>template_quality[index], <int>cmp_quality[index]
            )
        else:
            if(template_quality[index] < cmp_quality[index]):
                seq1[index] = seq2[index]
            template_quality[index] = MergeDiscQualities(
                <int>template_quality[index], <int>cmp_quality[index]
            )
    return


cdef AlignedSegment_t MergeBamRecs(AlignedSegment_t template,
                                   AlignedSegment_t cmp):
    cdef py_array qual1, qual2, seq1, seq2
    qual1 = template.opt("PV")
    qual2 = cmp.opt("PV")
    seq1 = array('B')
    seq2 = array('B')
    c_array.resize(seq1, template._delegate.core.l_qseq)
    c_array.resize(seq2, template._delegate.core.l_qseq)
    memcpy(seq1.data.as_shorts, bam_get_seq(template._delegate),
           template._delegate.core.l_qseq)
    memcpy(seq2.data.as_shorts, bam_get_seq(cmp._delegate),
           template._delegate.core.l_qseq)
    CompareSeqQual(<int32_t *>qual1.data.as_ints,
                   <int32_t *>qual2.data.as_ints,
                   <int8_t *>seq1.data.as_shorts,
                   <int8_t *>seq2.data.as_shorts,
                   template._delegate.core.l_qseq)
    template.set_tag("PV", qual1)
    template.query_sequence = seq1.tostring()
    return template


cpdef inline cystr pBamRescue(cystr inBam, cystr outBam, cystr tmpFq,
                              object mmlim=None):
    """
    :param inBam: [cystr/arg] - path to input bam
    :param outBam: [cystr/arg] - path to output bam
    :param mmlim: [object/kwarg/None] - mismatch limit
    If unset, defaults to DEFAULT_MMLIM (2)
    :return: [cystr]
    """
    if not mmlim:
        mmlim = DEFAULT_MMLIM
    else:
        mmlim = int(mmlim)
    sys.stderr.write("Now beginning BamRescue. mmlim: {}\n".format(mmlim))
    return BamRescue(inBam, outBam, tmpFq, mmlim)


cdef inline update_rec(AlignedSegment_t a, AlignedSegment_t b):
    cdef int i, newFM, newFP, readlen
    cdef char *a_seq = <char *>a.query_sequence
    cdef char *b_seq = <char *>b.query_sequence
    cdef py_array a_tmpqual = array('b', a.qual)
    cdef py_array a_qual = array('i', a.opt("PV"))
    cdef py_array b_qual = array('i', b.opt("PV"))
    cdef py_array a_FA = array('i', a.opt("FA"))
    cdef py_array b_FA = array('i', b.opt("FA"))
    # Increment FM tag.
    newFM = a.opt("FM") + b.opt("FM")
    # Increment RC tag.
    newRC = a.opt("RC") + b.opt("RC")
    # Let either read now pass via FP tag. Requires both reads being collapsed
    # pass
    newFP = a.opt("FP") and b.opt("FP")
    if(a.inferred_length is not None):
        readlen = a.inferred_length
    else:
        readlen = len(a.qual)
    for i in xrange(readlen):
        if(a_seq[i] == b_seq[i]):
            a_qual[i] = MergeAgreedQualities(a_qual[i], b_qual[i])
            a_FA[i] += b_FA[i]
        else:
            if(b_qual[i] > a_qual[i]):
                a_seq[i] = b_seq[i]
                a_FA[i] = b_FA[i]
            a_qual[i] = MergeDiscQualities(a_qual[i], b_qual[i])
    a.query_sequence = a_seq
    a.qual = a_tmpqual.tostring()
    a.set_tags(a.tags + [("FM", newFM, "i"), ("RC", newRC, "i"),
               ("FP", newFP, "i"), ("PV", a_qual), ("FA", a_FA)])
    return


cdef inline cystr bam2fq_header(AlignedSegment_t read):
    return "@%s RA:i:1\tPV:B:i,%s\tFA:B:i,%s\tFM:i:%i\tFP:i:%i\tRC:i:%i" % (
        read.query_name,
        ",".join(map(str, read.opt("PV"))),
        ",".join(map(str, read.opt("FA"))),
        read.opt("FM"),
        read.opt("FP"),
        read.opt("RC"))


cdef inline cystr bam2ffq(AlignedSegment_t read):
    if read.flag & 16:
        return "%s\n%s\n+\n%s\n" % (bam2fq_header(read),
                                    RevCmp(read.query_sequence),
                                    read.qual[::-1])
    else:
        return "%s\n%s\n+\n%s\n" % (bam2fq_header(read),
                                    read.query_sequence, read.qual)


cdef inline tuple BamRescueCore(list recList, int bLen, int mmlim,
                                int n_written):
    """
    :param inBam: [list/arg] - path to input bam
    :param bLen: [int/arg] - length of barcode
    :param mmlim: [int/arg] - mismatch limit
    """
    cdef AlignedSegment_t read
    cdef int listlen = len(recList)
    if listlen == 1:
        return recList, ""
    cdef int i, j
    cdef list bamList = []
    cdef cystr fq_text = ""
    cdef int ra_int
    for i in xrange(listlen):
        for j in xrange(i + 1, listlen):
            if(pBarcodeHD(recList[i], recList[j], bLen) < mmlim):
                '''
                skip_names.append(recList[i].query_name)
                '''
                recList[i].set_tags(recList[i].tags + [("RA", 0)])
                recList[j].set_tags(recList[j].tags + [("RA", 1)])
                update_rec(recList[j], recList[i])
                # Updates recList j with i's values for meta-analysis.
    for read in recList:
        ra_int = read.get_tag("RA")
        if(ra_int < 0):
            bamList.append(read)
        else:
            if(ra_int > 0):
                fq_text += bam2ffq(read)
                n_written += 1
    # assert fq_text is not None
    return bamList, fq_text


cpdef cystr BamRescueFull(cystr inBam, cystr outBam, cystr ref,
                          cystr opts=None,
                          int mmlim=DEFAULT_MMLIM, int threads=4):
    """
    :param: [cystr/arg] inBam - path to input bam.
    :param: [cystr/arg] outBam - path to final output bam.
    :param: [cystr/arg] ref - path to genome reference.
    :param: [cystr/kwarg/None] tmpBam - path to store temporary bam.
    :param: [cystr/kwarg/None] tmpFq - Path to store temporary fastqs.
    :param: [cystr/kwarg/None] opts - Options to pass to bwa.
    :param: [int/kwarg/2] mmlim - mismatch threshold for considering reads to
    be from the same family.
    :param: [int/kwargs/4] threads - number of threads to use for samtools
    merge and bwa mem.
    :return: [cystr] outBam - Path to final output bam.
    """
    if ref is None:
        raise Tim("Reference fasta required for BamRescueFull!")
    random_prefix = str(uuid.uuid4().get_hex()[0:8])
    tmpFq = TrimExt(inBam) + ".ra.fastq"
    tmpBam = random_prefix + ".ra.tmp.bam"
    print("tmpFq: %s. tmpBam: %s" % (tmpFq, tmpBam))
    # Make the temporary fastq for reads that need to be realigned.
    tmpFq = BamRescue(inBam, tmpBam, tmpFq, mmlim=mmlim)
    if opts is None:
        opts = "-t %i -v 1 -Y -T 0" % threads
    # Name sort, then align this fastq, sort it, then merge it into the tmpBam
    cStr = ("cat %s | paste -d'~' - - - - | sort -k1,1 | tr '~' " % tmpFq +
            "'\n' | bwa mem -C -p %s %s - | samtools sort " % (opts, ref) +
            "-O bam -l 0 -T %s - | samtools merge -f " % (random_prefix) +
            "-@ %i %s %s -" % (threads, outBam, tmpBam))
    fprintf(stderr, "Command string: '%s'\n", <char *>cStr)
    check_call(cStr, shell=True)
    fprintf(stderr, "Now deleting temporary bam %s and temporary fastq %s.\n",
            <char *>tmpBam, <char *>tmpFq)
    check_call(["rm", tmpBam, tmpFq])
    fprintf(stderr, "Successfully completed BamRescueFull.\n")
    return outBam


cdef cystr BamRescue(cystr inBam,
                     cystr outBam,
                     cystr tmpFq,
                     int mmlim=DEFAULT_MMLIM):
    """
    :param: inBam [cystr/arg] Path to input bam.
    :param: outBam [cystr/arg] Path to output bam.
    :param: tmpFq [cystr/arg] Path to output fastq.
    Set to "-" to default to sdtout.
    :param: mmlim [int/kwarg/2] Mismatch limit for barcode rescue.
    Hamming distances less than mmlim are considered to be from the same
    original founding molecule.
    :param: [cystr] Path to temporary fastq.
    """
    cdef AlignedSegment_t read
    cdef list recList
    cdef bint Pass
    cdef cystr fq_text
    cdef uint64_t n_written = 0
    if tmpFq == "-":
        fp = sys.stdout
        fprintf(stderr, "Writing fastq to stdout.\n")
    else:
        try:
            fp = open(tmpFq, "w")
        except IOError:
            print("tmpFq: %s." % tmpFq)
            sys.exit(137)
        fprintf(stderr, "Writing fastq to %s.\n", <char *>tmpFq)
    fprintf(stderr, "Now opening bam file for reading: %s\n", <char *>inBam)
    input_bam = pysam.AlignmentFile(inBam, "rb")
    cdef int bLen = 0
    try:
        blen = len(input_bam.next().query_name)
    except StopIteration:
        fprintf(stderr, "Looks like this bam is simply empty. "
                "Make an empty fastq.\n")
        fp.close()
        return tmpFq
    input_bam = pysam.AlignmentFile(inBam, "rb")
    if outBam == "default":
        outBam = TrimExt(inBam) + ".rescue.bam"
    fprintf(stderr, "Now opening output bam %s\n",
            <char *>(outBam if(outBam != "-") else "stdout"))
    output_bam = pysam.AlignmentFile(outBam, "wb",
                                     template=input_bam)
    obw = output_bam.write
    fpw = fp.write
    for Pass, gen in groupby(input_bam, SKIP_READS):
        if not Pass:
            recList = list(gen)
            for read in recList:
                if read.has_tag("RC") is False:
                    read.set_tags(read.tags + [("RC", -1), ("RA", -1)])
                else:
                    read.set_tags(read.tags + [("RA", -1)])
            [obw(read) for read in recList]
            continue
        for fullkey, gen1 in groupby(gen, FULL_KEY):
            recList = list(gen1)
            for read in recList:
                if read.has_tag("RC") is False:
                    read.set_tags(read.tags + [("RC", -1), ("RA", -1)])
                else:
                    read.set_tags(read.tags + [("RA", -1)])
            if recList[0].flag & 12:
                # Both read and its mate are unaligned.
                [obw(read) for read in recList]
            else:
                recList, fq_text = BamRescueCore(recList, bLen,
                                                 mmlim, n_written)
                [obw(read) for read in recList]
                fpw(fq_text)
    input_bam.close()
    output_bam.close()
    fp.close()
    fprintf(stderr,
            "Number of records written: "
            "%lu. Output path: %s.\n", n_written, <char *>output_bam.filename)
    if(os.path.isfile(outBam) is False and outBam != "-"):
        raise Tim("Output bam '%' didn't get made. WTF???")
    return tmpFq


cdef inline int8_t StringHD(char *str1, char *str2, int8_t bLen) nogil:
    cdef size_t index
    cdef int8_t ret = 0
    for index in range(bLen):
        if(str1[index] != str2[index]):
            ret += 1
    return ret


cdef inline pBarcodeHD(AlignedSegment_t query, AlignedSegment_t cmp,
                       int bLen):
    cdef cystr BC1, BC2
    BC1 = query.query_name
    BC2 = cmp.query_name
    return StringHD(<char*> BC1, <char*> BC2, bLen)
