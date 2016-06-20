# cython: c_string_type=str, c_string_encoding=ascii
from itertools import tee
from operator import methodcaller as mc
from subprocess import CalledProcessError
import decimal
import logging
import operator
import sys
from cStringIO import InputType, OutputType
from subprocess import check_call, check_output
import numpy as np
from numpy import sum as nsum
from numpy import mean as nmean
from numpy import min as nmin
import cython
import pysam
from os import path as ospath
from bmfutil.HTSUtils import (printlog as pl,
                              SortBgzipAndTabixVCF, is_reverse_to_str)
from bmfutil import HTSUtils
from bmfutil.ErrorHandling import ThisIsMadness as Tim

cimport cython
cimport pysam.ctabixproxies
ctypedef cython.str cystr

"""
Contains tools for working with VCF Files - writing, reading, processing.
"""


class VCFFile:

    """A simple VCFFile object, consisting of a header, a name for the file
    from which they came, and a list of all VCFRecords.
    Access header through self.header (list of strings, one for each line)
    Access VCF Entries through self.Records (list of VCFRecord objects)
    """

    def __init__(self, VCFEntries, VCFHeader, inputVCFName):
        self.sampleName = inputVCFName
        self.header = VCFHeader
        self.Records = VCFEntries
        self.sampleNamesArray = [inputVCFName]
        self.numSamples = len(self.sampleNamesArray)

    def cleanRecords(self):
        self.Records = [entry for entry in self.Records if entry.ALT != "<X>"]

    def filter(self, filterOpt="default", param="default"):
        if(filterOpt == "default"):
            try:
                raise ValueError(
                    "Filter method required")
            except ValueError:
                print("Returning nothing.")
                return
        NewVCFEntries = []
        for entry in self.Records:
            if(VCFRecordTest(entry, filterOpt, param=param)):
                NewVCFEntries.append(entry)
        if(filterOpt == "bed"):
            if(param == "default"):
                try:
                    raise ValueError("Bed file required for bedfilter.")
                except ValueError:
                    print("Returning nothing.")
            filterOpt = filterOpt + "&" + param
        NewVCFFile = VCFFile(NewVCFEntries, self.header, self.sampleName +
                             "FilteredBy{}".format(filterOpt))
        return NewVCFFile

    def update(self):
        SetNames = []
        for record in self.Records:
            record.update()
            SetNames.append(record.VCFFilename)
        self.sampleNamesArray = list(set(SetNames))
        self.numSamples = len(self.sampleNamesArray)

    def len(self):
        try:
            return len(self.Records)
        except AttributeError:
            raise AttributeError("VCFFile object not initialized.")

    def write(self, Filename):
        FileHandle = open(Filename, "w")
        for headerLine in self.header:
            FileHandle.write("{}\n".format(headerLine))
        for VCFEntry in self.Records:
            FileHandle.write("{}\n".format(str(VCFEntry)))
        FileHandle.close()
        return

    def GetLoFreqVariants(self, outVCF="default", replace=False):
        NewVCFEntries = [entry for entry in self.Records if VCFRecordTest(
                         entry, filterOpt="I16", param="3")]
        NewVCF = VCFFile(NewVCFEntries,
                         self.header,
                         self.sampleName.replace(".vcf", "") + ".lofreq.vcf")
        if(replace):
            self = NewVCF
        if(outVCF == "default"):
            pl("outVCF not set, not writing to file.")
        else:
            self.write(outVCF)
        return NewVCF


class VCFRecord:

    """A simple VCFRecord object, taken from an item from
    the list which ParseVCF returns as "VCFEntries" """

    def __init__(self, VCFEntry, VCFFilename):
        self.CHROM = VCFEntry[0]
        if(VCFEntry[0] == ""):
            self.ALT = "."
            self.POS = "."
            self.ID = "."
            self.REF = "REF"
            self.QUAL = "NoCall"
            return None
        try:
            self.POS = int(VCFEntry[1])
        except IndexError:
            print("Line: {}".format(VCFEntry))
            raise Tim("Something went wrong.")
        except ValueError:
            print(repr(VCFEntry))
            raise Tim("Improperly formatted VCF.")
        self.ID = VCFEntry[2]
        self.REF = VCFEntry[3]
        if("<X>" in VCFEntry[4]):
            self.ALT = VCFEntry[4].replace(",<X>", "")
        else:
            self.ALT = VCFEntry[4]
        self.QUAL = VCFEntry[5]
        self.FILTER = VCFEntry[6]
        self.INFO = VCFEntry[7]
        self.InfoKeys = [entry.split('=')[0] for entry in
                         self.INFO.split(';') if
                         len(entry.split("=")) != 1]
        self.InfoValues = []
        self.InfoUnpaired = []
        for entry in self.INFO.split(';'):
            #  print("entry: {}. INFO: {}".format(entry, self.INFO))
            try:
                self.InfoValues.append(entry.split('=')[1])
            except IndexError:
                self.InfoUnpaired.append(entry)
                continue
        #  print(self.InfoValues)
        #  Might not reproduce the original information when written to file.
        tempValArrays = [entry.split(',') for entry in self.InfoValues]
        try:
            self.InfoValArrays = [
                [entry for entry in array] for array in tempValArrays]
        except ValueError:
            self.InfoValArrays = [
                [entry for entry in array] for array in tempValArrays]
        self.InfoDict = dict(zip(self.InfoKeys, self.InfoValues))
        self.InfoArrayDict = dict(zip(self.InfoKeys, self.InfoValArrays))
        try:
            self.InfoArrayDict['I16'] = [
                int(i) for i in self.InfoArrayDict['I16']]
        except ValueError:
            if("I16" in self.InfoArrayDict.keys()):
                self.InfoArrayDict['I16'] = [
                    int(decimal.Decimal(i)) for i in self.InfoArrayDict['I16']]
        except KeyError:
            pass
            # print("No I16 present; continuing.")
        try:
            self.FORMAT = VCFEntry[8]
        except IndexError:
            self.FORMAT = ""
        try:
            self.GENOTYPE = VCFEntry[9]
        except IndexError:
            self.GENOTYPE = ""
        self.GenotypeDict = dict(
            zip(self.FORMAT.split(':'), self.GENOTYPE.split(':')))
        self.GenotypeKeys = self.FORMAT.split(':')
        self.GenotypeValues = self.GENOTYPE.split(':')
        self.Samples = []
        if(len(VCFEntry) > 10):
            for field in VCFEntry[10:]:
                self.Samples.append(field)
        self.VCFFilename = VCFFilename
        if(len(self.Samples) == 0):
            recordStr = '\t'.join(np.array([self.CHROM,
                                           self.POS,
                                           self.ID,
                                           self.REF,
                                           self.ALT,
                                           self.QUAL, self.FILTER,
                                           self.INFO, self.FORMAT,
                                           self.GENOTYPE]).astype(str))
        else:
            sampleStr = "\t".join(self.Samples)
            recordStr = '\t'.join(np.array([self.CHROM,
                                           self.POS, self.ID,
                                           self.REF, self.ALT,
                                           self.QUAL, self.FILTER, self.INFO,
                                           self.FORMAT,
                                           self.GENOTYPE,
                                           sampleStr]).astype(str))
        self.str = recordStr.strip()

    def update(self):
        self.InfoKeys = sorted(self.InfoDict.iterkeys())
        self.InfoValues = [self.InfoDict[key] for key in self.InfoKeys]
        infoEntryArray = [InfoKey + "=" + InfoValue for InfoKey,
                          InfoValue in zip(self.InfoKeys, self.InfoValues)]
        self.INFO = ';'.join(infoEntryArray + self.InfoUnpaired)
        tempValArrays = [entry.split(',') for entry in self.InfoValues]
        self.InfoValArrays = [
            [entry for entry in array] for array in tempValArrays]
        self.InfoArrayDict = dict(zip(self.InfoKeys, self.InfoValArrays))
        if('I16' in self.InfoArrayDict.keys()):
            try:
                self.InfoArrayDict['I16'] = [
                    int(i) for i in self.InfoArrayDict['I16']]
            except ValueError:
                if("I16" in self.InfoArrayDict.keys()):
                    self.InfoArrayDict['I16'] = [
                        int(decimal.Decimal(
                            i)) for i in self.InfoArrayDict['I16']]
        self.GenotypeKeys = sorted(self.GenotypeDict.iterkeys())
        self.GenotypeValues = [self.GenotypeDict[key] for key
                               in self.GenotypeKeys]
        self.FORMAT = ":".join(self.GenotypeKeys)
        self.GENOTYPE = ":".join(self.GenotypeValues)
        if(len(self.Samples) == 0):
            recordStr = '\t'.join([str(i) for i in [self.CHROM, self.POS,
                                   self.ID, self.REF, self.ALT, self.QUAL,
                                   self.FILTER, self.INFO, self.FORMAT,
                                   self.GENOTYPE]])
        else:
            print("Sample is being used...")
            sampleStr = "\t".join(self.Samples)
            recordStr = '\t'.join([str(i) for i in [self.CHROM, self.POS,
                                                    self.ID,
                                   self.REF, self.ALT, self.QUAL,
                                   self.FILTER, self.INFO, self.FORMAT,
                                   self.GENOTYPE, sampleStr]])
        self.str = recordStr.strip().replace("\n", "")

    def __str__(self):
        self.update()
        return self.str


class IterativeVCFFile:

    def __init__(self, VCFFilename):
        if(not isinstance(VCFFilename, file) and not
           isinstance(VCFFilename, InputType) and not
           isinstance(VCFFilename, OutputType)):
            self.handle = open(VCFFilename, "r")
            self.Filename = VCFFilename
            #  If the file is a cStringIO object, it will still work.
        else:
            self.handle = VCFFilename
            self.Filename = str(VCFFilename)
        self.header = []
        realIterator, checker = tee(self.handle)
        while True:
            if(checker.next()[0] == "#"):
                self.header.append(realIterator.next().strip())
            else:
                break

    def __iter__(self):
        return self

    def next(self):
        return VCFRecord(self.handle.next().strip().split('\t'),
                         self.Filename)


def ParseVCF(inputVCFName):
    try:
        infile = open(inputVCFName, "r")
    except TypeError:
        raise TypeError("Argument provided: {}".format(inputVCFName))
    VCFLines = [entry.strip().split('\t') for entry in infile.readlines(
    ) if entry[0] != "#" and entry != ""]
    infile.seek(0)
    VCFHeader = [entry.strip(
    ) for entry in infile.readlines() if entry[0] == "#" and entry[0] != ""]
    VCFEntries = [VCFRecord(
        line, inputVCFName) for line in VCFLines if len(line) >= 7]
    ParsedVCF = VCFFile(VCFEntries, VCFHeader, inputVCFName)
    return ParsedVCF


def VCFRecordTest(inputVCFRec, filterOpt="default", param="default"):
    cdef cystr tmpStr
    lst = [tmpStr.lower() for tmpStr in "bed,I16".split(",")]
    # print("lst = {}".format(lst))
    if(filterOpt.lower() not in lst):
        raise ValueError(("Filter option not supported. Available options: " +
                          ', '.join(lst)))
    passRecord = True
    if(filterOpt == "default"):
        raise ValueError("Filter option required.")
    if(filterOpt == "bed"):
        if(param == "default"):
            raise ValueError("Bedfile req. for bed filter.")
        bedReader = open(param, 'r')
        bedEntries = [l.strip().split('\t') for l in bedReader.readlines()]
        chr, pos = inputVCFRec.CHROM, inputVCFRec.POS
        chrMatches = [ent for ent in bedEntries if ent[0] == chr]
        try:
            posMatches = [match for match in chrMatches if match[
                          2] + 1 >= pos and match[1] + 1 <= pos]
            if len(posMatches) >= 1 and passRecord:
                passRecord = True
            else:
                passRecord = False
        except ValueError:
            raise ValueError("Malformed bedfile.")
            # return False
    # Set param to int, where it is the minimum dissent reads
    if(filterOpt == "I16"):
        if(param == "default"):
            raise ValueError("Minimum # dissenting reads must be set.")
        param = int(param)
        ConsensusIsRef = True
        I16Array = np.array(inputVCFRec.InfoArrayDict['I16']).astype("int")
        if(nsum(I16Array[0:2]) < nsum(I16Array[2:4])):
            ConsensusIsRef = False
        if(ConsensusIsRef):
            if(nsum(I16Array[2:4]) > param):
                return True
            else:
                return False
        else:
            if(nsum(I16Array[0:2]) > param):
                return True
            else:
                return False
    return passRecord


def VCFStats(inVCF, TransCountsTable="default"):
    print("About to run VCFStats on {}".format(inVCF))
    if(TransCountsTable == "default"):
        TransCountsTable = inVCF[0:-3] + "trans.vcf.tsv"
    pl("VCFStats table: {}".format(TransCountsTable))
    inVCF = ParseVCF(inVCF)
    TransCountsTableHandle = open(TransCountsTable, "w")
    TransitionDict = {}
    TransitionPASSDict = {}
    TransitionCountsDict = {}
    TransitionCountsPASSDict = {}
    RefConsCallsCountsDict = {}
    RefConsCallsCountsPASSDict = {}
    TransCountsTableHandle.write("Transition\tCount\tCount marked \"PASS"
                                 "\"\tFraction Of Calls With Given Ref/Cons\t"
                                 "MeanAlleleFraction\tFraction Of PASS Calls "
                                 "With Given Ref/Cons\tMean Allele Fraction "
                                 "Of PASS Calls\n")
    for RefCons in ["A", "C", "G", "T"]:
        for Var in ["A", "C", "G", "T"]:
            if(RefCons == Var):
                continue
            TransitionDict[RefCons + "-->" + Var] = [
                rec for rec
                in inVCF.Records
                if rec.GenotypeDict['CONS'] == RefCons or
                rec.REF == RefCons and rec.ALT == Var]
            TransitionPASSDict[RefCons + "-->" + Var] = [
                rec for rec
                in inVCF.Records
                if (rec.GenotypeDict['CONS'] == RefCons or
                    rec.REF == RefCons) and (rec.FILTER == "PASS" and
                                             rec.ALT == Var)]
            TransitionCountsDict[RefCons + "-->" + Var] = len(
                TransitionDict[RefCons + "-->" + Var])
            TransitionCountsPASSDict[RefCons + "-->" + Var] = len(
                TransitionPASSDict[RefCons + "-->" + Var])
    for RefCons in ["A", "C", "G", "T"]:
        for key in TransitionCountsDict.iterkeys():
            if key[0] == RefCons:
                try:
                    RefConsCallsCountsDict[
                        RefCons] += TransitionCountsDict[key]
                except KeyError:
                    RefConsCallsCountsDict[RefCons] = TransitionCountsDict[key]
                try:
                    RefConsCallsCountsPASSDict[
                        RefCons] += TransitionCountsPASSDict[key]
                except KeyError:
                    RefConsCallsCountsPASSDict[
                        RefCons] = TransitionCountsPASSDict[key]
    MeanAlleleFractionDict = {}
    MeanAlleleFractionPASSDict = {}
    for key in TransitionCountsDict.iterkeys():
        MeanAlleleFractionDict[key] = nmean(
            [float(rec.InfoDict['AF']) for rec in
                TransitionDict[key] if float(rec.InfoDict['AF']) < 0.1])
        MeanAlleleFractionPASSDict[key] = nmean(
            [float(rec.InfoDict['AF'])for rec in
             TransitionPASSDict[key] if float(rec.InfoDict['AF']) < 0.1])
    TransitionFractionForRefConsDict = {}
    TransitionFractionForRefConsPASSDict = {}
    for key in TransitionCountsDict.iterkeys():
        try:
            TransitionFractionForRefConsDict[
                key] = (1. * TransitionCountsDict[key] /
                        RefConsCallsCountsDict[key[0]])
        except ZeroDivisionError:
            TransitionFractionForRefConsDict[key] = 0
        try:
            TransitionFractionForRefConsPASSDict[
                key] = (1. * TransitionCountsPASSDict[key] /
                        RefConsCallsCountsPASSDict[key[0]])
        except ZeroDivisionError:
            TransitionFractionForRefConsPASSDict[key] = 0
    for key in TransitionCountsDict.iterkeys():
        TransCountsTableHandle.write("\t".join(
            [str(i)[0:8] for i in [key,
                                   TransitionCountsDict[key],
                                   TransitionCountsPASSDict[key],
                                   TransitionFractionForRefConsDict[key],
                                   MeanAlleleFractionDict[key],
                                   TransitionFractionForRefConsPASSDict[key],
                                   MeanAlleleFractionPASSDict[key]
                                   ]]) + "\n")
    TransCountsTableHandle.close()
    return TransCountsTable


def FilterGZVCFByBed(inVCF, bedfile="default", outVCF="default"):
    if(inVCF[:-3] == "vcf"):
        pl("vcf file not bgzipped - sorting, bgzipping and tabixing.")
        inVCF = SortBgzipAndTabixVCF(inVCF)
    elif(inVCF[:-3] == ".gz"):
        raise Tim("Unrecognized file extension - either "
                  "accepts bgzipped or unzipped vcf files.")
    if(outVCF == "default"):
        outVCF = inVCF[0:-7] + ".bedfilter.vcf.gz"
    print("bedfile used: {}".format(bedfile))
    check_call("bcftools -R %s %s -O z > %s" % (bedfile, inVCF, outVCF))
    return outVCF


def SplitVCFRecMultipleAlts(inVCFRecord):
    """
    Takes as input a VCF Record with multiple alts, then returns a list of
    VCFRecord objects with one alt per line.
    """
    assert isinstance(inVCFRecord, VCFRecord)
    splitLines = []
    if("," in inVCFRecord.ALT):
        NewInfoDict = {}
        for count, AltAllele in enumerate(inVCFRecord.ALT.split(',')):
            for key in inVCFRecord.InfoDict:
                if(len(inVCFRecord.InfoDict[key].split(',')) == len(
                        inVCFRecord.ALT.split(','))):
                    NewInfoDict[key] = inVCFRecord.InfoDict[
                        key].split(',')[count]
                else:
                    NewInfoDict[key] = inVCFRecord.InfoDict[key]
                infoEntryArray = [InfoKey + "=" + InfoValue for InfoKey,
                                  InfoValue in zip(NewInfoDict.iterkeys(),
                                                   NewInfoDict.itervalues())]
                INFO = (';'.join(infoEntryArray +
                                 inVCFRecord.InfoUnpaired)).replace("\n", "")
            FORMAT = ":".join(inVCFRecord.GenotypeKeys)
            GENOTYPE = ":".join(inVCFRecord.GenotypeValues)
            if(len(inVCFRecord.Samples) == 0):
                splitLines.append(VCFRecord([inVCFRecord.CHROM,
                                             inVCFRecord.POS,
                                             inVCFRecord.ID,
                                             inVCFRecord.REF,
                                             AltAllele,
                                             inVCFRecord.QUAL,
                                             inVCFRecord.FILTER, INFO,
                                             FORMAT, GENOTYPE],
                                            inVCFRecord.VCFFilename))
            else:
                sampleStr = "\t".join(inVCFRecord.Samples)
                splitLines.append(VCFRecord([inVCFRecord.CHROM,
                                             inVCFRecord.POS,
                                             inVCFRecord.ID,
                                             inVCFRecord.REF,
                                             AltAllele,
                                             inVCFRecord.QUAL,
                                             inVCFRecord.FILTER, INFO,
                                             FORMAT, GENOTYPE, sampleStr],
                                            inVCFRecord.VCFFilename))
    else:
        return [inVCFRecord]
    return splitLines


def ISplitMultipleAlts(inVCF, outVCF="default"):
    """
    A simple function for splitting VCF lines with multiple
    ALTs into several valid lines.
    """
    print("Beginning SplitMultipleAlts")
    if(outVCF == "default"):
        print("OutputVCF is default - changing!")
        outVCF = '.'.join(inVCF.split('.')[0:-1]) + '.AltSplit.vcf'
    print("Output VCF: {}".format(outVCF))
    inVCF = IterativeVCFFile(inVCF)
    outHandle = open(outVCF, "w")
    outHandle.write("\n".join(inVCF.header) + "\n")
    outLines = []
    numK = 0
    count = 0
    for line in inVCF:
        if(len(outLines) >= 10000):
            outHandle.write("\n".join([line.__str__() for line in outLines]))
            outLines = []
            numK += 1
            print("Number of processed lines: {}".format(10000 * numK))
        if("," in line.ALT):
            outLines += SplitVCFRecMultipleAlts(line)
        else:
            outLines.append(line)
    outStr = "\n".join([line.str for line in outLines])
    outHandle.write(outStr)
    outHandle.close()
    print("Output VCF: {}".format(outVCF))
    print("Number of lines split: {}".format(count))
    return outVCF


@cython.locals(maxAF=float,
               recFreq=float, recordsPerWrite=int)
def IFilterByAF(inVCF, outVCF="default", maxAF=0.1,
                recordsPerWrite=50000):
    """
    A simple function for splitting VCF lines with multiple
    ALTs into several valid lines.
    """
    print("Beginning SplitMultipleAlts")
    if(outVCF == "default"):
        print("OutputVCF is default - changing!")
        outVCF = '.'.join(inVCF.split('.')[0:-1] + ["AFFilt", str(maxAF),
                                                    "vcf"])
    print("Output VCF: {}".format(outVCF))
    inVCF = IterativeVCFFile(inVCF)
    outHandle = open(outVCF, "w")
    outHandle.write("\n".join(inVCF.header) + "\n")
    outLines = []
    numK = 0
    count = 0
    for rec in inVCF:
        if len(outLines) > recordsPerWrite:
            outHandle.write("\n".join(outLines) + "\n")
            outLines = []
        try:
            recFreq = float(rec.InfoDict["AF"])
        except ValueError:
            pl("Looks like this record might have multiple AFs. Just keep it "
               "if at least one record is under that maxAF")
            recFreq = np.min([float(i) for i in
                              rec.InfoDict["AF"].split(",")],
                             dtype=np.float64)
        if recFreq < maxAF:
            outLines.append(rec.__str__())
    if len(outLines) != 0:
        outHandle.write("\n".join(outLines))
    outHandle.flush()
    outHandle.close()
    return outVCF


def GetPotentialHetsVCF(inVCF, minHetFrac=0.025,
                        maxHetFrac=1, outVCF="default",
                        replaceIDWithHetFreq=True):
    """
    Gets a list of potentially heterozygous sites, parsing in from
    the ExAC VCF.
    """
    if(outVCF == "default"):
        outVCF = inVCF[0:-3] + 'ExAC63K.het.vcf'
    pl("Input VCF: {}.".format(inVCF))
    pl("minHetFrac: {}.".format(minHetFrac))
    pl("maxHetFrac: {}.".format(maxHetFrac))
    outHandle = open(outVCF, "w")
    IVCF = IterativeVCFFile(inVCF)
    outHandle.write("\n".join(IVCF.header) + "\n")
    for VCFRec in IVCF:
        try:
            hetFreq = float(VCFRec.InfoDict["AC_Het"]) * 2 / int(
                VCFRec.InfoDict["AN"])
        except KeyError:
            # print(repr(VCFRec.InfoDict))
            # print("This record has no AC_Het field. Continue!")
            continue
        except ValueError:
            hetFreq = sum([int(i) for i in VCFRec.InfoDict[
                "AC_Het"].split(',')]) / float(VCFRec.InfoDict["AN"])
        if(hetFreq >= minHetFrac and hetFreq <= maxHetFrac):
            if(replaceIDWithHetFreq):
                VCFRec.ID = str(hetFreq)[0:6]
            outHandle.write(str(VCFRec) + "\n")
    outHandle.close()


def GetPotentialHetsVCFUK10K(inVCF, minAlFrac=0.2,
                             maxAlFrac=0.8, outVCF="default",
                             replaceIDWithAlFreq=True):
    """
    Gets a list of potentially heterozygous sites, parsing in from
    the UK10K VCF.
    """
    if(outVCF == "default"):
        outVCF = inVCF[0:-3] + 'UK10K.het.vcf'
    pl("Input VCF: {}.".format(inVCF))
    pl("minAlFrac: {}.".format(minAlFrac))
    pl("maxAlFrac: {}.".format(maxAlFrac))
    outHandle = open(outVCF, "w")
    IVCF = IterativeVCFFile(inVCF)
    outHandle.write("\n".join(IVCF.header) + "\n")
    for VCFRec in IVCF:
        try:
            alleleFreq = float(VCFRec.InfoDict["AF"])
        except KeyError:
            # print(repr(VCFRec.InfoDict))
            # print("This record has no AC_Het field. Continue!")
            continue
        if(alleleFreq >= minAlFrac and alleleFreq <= maxAlFrac):
            if(replaceIDWithAlFreq):
                VCFRec.ID = str(alleleFreq)[0:6]
            outHandle.write(str(VCFRec) + "\n")
    outHandle.close()


@cython.locals(nAllelesAtPos=int)
def CheckVCFForStdCalls(inVCF, std="default", outfile="default"):
    """
    Verifies the absence or presence of variants that should be in a VCF.
    """
    cdef pysam.ctabixproxies.VCFProxy rec, qRec, i
    if(std == "default"):
        raise Tim("Standard file (must be CHR/POS/ID/REF/ALT), vari"
                  "able name 'std', must be set to CompareVCFToStan"
                  "dardSpecs")
    if(outfile == "default"):
        outHandle = sys.stdout
    else:
        outHandle = open(outfile, "w")
    ohw = outHandle.write
    asVCF = pysam.asVCF()
    if(ospath.isfile(std + ".tbi") is False):
        pl("No tabix index found for standard - sorting, "
           "bgzipping, and tabixing.")
        std = SortBgzipAndTabixVCF(std)
    if(ospath.isfile(inVCF + ".tbi") is False):
        pl("No tabix index found for query VCF - sorting, "
           "bgzipping, and tabixing.")
        inVCF = SortBgzipAndTabixVCF(inVCF)
    refIterator = pysam.tabix_iterator(open(std, "rb"), asVCF)
    queryHandle = pysam.TabixFile(inVCF, parser=asVCF)
    ohw("\t".join(["#VariantPositionAndType", "FoundMatch", "Filter",
                   "ObservedAF", "NumVariantsCalledAtPos", "DOC",
                   "refVCFLine", "queryVCFLine"]) + "\n")
    qhf = queryHandle.fetch
    for rec in refIterator:
        # Load all records with precisely our ref record's position
        try:
            queryRecs = list(qhf(rec.contig, rec.pos - 6, rec.pos + 6))
        except ValueError:
            pl("Looks like contig %s just isn't in the tabix'd" % rec.contig +
               "file. Give up - continuing!", level=logging.DEBUG)
            ohw("\t".join([":".join([rec.contig, str(rec.pos),
                                     rec.ref, rec.alt]),
                           "False", "N/A", "N/A", str(nAllelesAtPos), "-1",
                           str(rec).replace("\t", "&"), "N/A"]) + "\n")
            continue
        queryRecs = [i for i in queryRecs if i.ref == rec.ref and
                     i.pos == rec.pos]
        nAllelesAtPos = len(queryRecs)
        queryRecs = [i for i in queryRecs if i.alt == rec.alt]
        # Get just the record (or no record) that has that alt.
        if(nAllelesAtPos == 0):
            pl("No variants called at position. %s " % str(rec))
            ohw("\t".join([":".join([rec.contig, str(rec.pos),
                                     rec.ref, rec.alt]),
                           "False", "N/A", "N/A", str(nAllelesAtPos), "-1",
                           str(rec).replace("\t", "&"), "N/A"]) + "\n")
            continue
        if(len(queryRecs) == 0):
            pl("Looks like the rec: "
               "%s wasn't called at all." % (str(rec)))
            ohw("\t".join([":".join([rec.contig, str(rec.pos),
                                     rec.ref, rec.alt]),
                           "False", "N/A", "N/A", str(nAllelesAtPos), "-1",
                           str(rec).replace("\t", "&"), "N/A"]) + "\n")
            continue
        qRec = queryRecs[0]
        ohw("\t".join([":".join([rec.contig, str(rec.pos), rec.ref, rec.alt]),
                       "True", qRec.filter,
                       dict([f.split("=") for f in
                             qRec.info.split(";")])["AF"],
                       str(nAllelesAtPos),
                       dict(zip(qRec.format.split(":"),
                                qRec[0].split(":")))["DP"],
                       str(rec).replace("\t", "&"),
                       str(qRec).replace("\t", "&")]) + "\n")
    return outfile


def CheckStdCallsForVCFCalls(inVCF, std="default", outfile=sys.stdout,
                             acceptableFilters="PASS"):
    """
    Iterates through an input VCF to find variants without any filters outside
    of "acceptableFilters". (which should be a comma-separated list of strings)
    """
    cdef pysam.ctabixproxies.VCFProxy rec, qRec, i
    cdef int lRefRecs
    if(std == "default"):
        raise Tim("Standard file (must be CHR/POS/ID/REF/ALT), vari"
                  "able name 'std', must be set to CheckStdCallsFor"
                  "VCFCalls")
    if(not isinstance(outfile, file)):
        if(not isinstance(outfile, str)):
            raise Tim("outfile variable is neither a file nor a "
                      "string. I don't know what to do with this - "
                      "check your kwargs!")
        outfile = open(outfile, "w")
    ofw = outfile.write
    asVCF = pysam.asVCF()
    vcfIterator = pysam.tabix_iterator(open(inVCF, "rb"), asVCF)
    refHandle = pysam.TabixFile(std, parser=asVCF)
    ofw("\t".join(["#VariantPositionAndType", "FoundMatch", "Filter",
                   "ObservedAF", "DOC", "refVCFLine", "queryVCFLine"]))
    rhf = refHandle.fetch
    for qRec in vcfIterator:
        filtlist = qRec.filter.split(",")
        if(sum([filt for filt in filtlist if filt
                not in acceptableFilters]) != 0):
            continue
        refRecs = [i for i in list(rhf(qRec.contig,
                                       qRec.pos - 1, qRec.pos))
                   if i.alt == qRec.alt]
        lRefRecs = len(refRecs)
        if(lRefRecs == 0):
            ofw("\t".join([":".join([qRec.contig, str(qRec.pos),
                                     qRec.ref, qRec.alt]),
                           "False", qRec.filter,
                           dict([f.split("=") for f in
                                 qRec.info.split(";")])["AF"],
                           dict(zip(qRec.format.split(":"),
                                    qRec[0].split(":")))["DP"], "N/A",
                           str(qRec).replace("\t", "&")]))
            continue
        if(lRefRecs == 1):
            rec = refRecs[0]
            ofw("\t".join([":".join([qRec.contig, str(qRec.pos),
                                     qRec.ref, qRec.alt]),
                           "True", qRec.filter,
                           dict([f.split("=") for f in
                                 qRec.info.split(";")])["AF"],
                           dict(zip(qRec.format.split(":"),
                                    qRec[0].split(":")))["DP"],
                           str(rec).replace("\t", "&"),
                           str(qRec).replace("\t", "&")]))
            continue
        raise Tim("Unexpected behavior - reference VCF shouldn't ha"
                  "ve more than one line with the same alt, should "
                  "it?")
    return outfile
