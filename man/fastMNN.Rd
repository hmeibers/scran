\name{fastMNN}
\alias{fastMNN}

\title{Fast mutual nearest neighbors correction}
\description{Correct for batch effects in single-cell expression data using the mutual nearest neighbors (MNN) method.}

\usage{
fastMNN(..., k=20, cos.norm=TRUE, ndist=3, d=50, approximate=FALSE, 
    irlba.args=list(), subset.row=NULL, auto.order=FALSE, pc.input=FALSE,
    assay.type="logcounts", use.spikes=FALSE, BPPARAM=SerialParam()) 
}

\arguments{
\item{...}{Two or more log-expression matrices where genes correspond to rows and cells correspond to columns.
One matrix should contain cells from the same batch; multiple matrices represent separate batches of cells.
Each matrix should contain the same number of rows, corresponding to the same genes (in the same order).

Alternatively, two or more SingleCellExperiment objects can be supplied, where each object contains a log-expression matrix in the \code{assay.type} assay.

Alternatively, two or more matrices of low-dimensional representations can be supplied if \code{pc.input=TRUE}.
Here, rows are cells and columns are dimensions (the latter should be common across all batches).}
\item{k}{An integer scalar specifying the number of nearest neighbors to consider when identifying MNNs.}
\item{cos.norm}{A logical scalar indicating whether cosine normalization should be performed on the input data prior to calculating distances between cells.}
\item{ndist}{A numeric scalar specifying the threshold beyond which neighbours are to be ignored when computing correction vectors.
Each threshold is defined in terms of the number of median distances.}
\item{d, approximate, irlba.args}{Further arguments to pass to \code{\link{multiBatchPCA}}.}
\item{subset.row}{A vector specifying the genes to use, providing equivalent behaviour to subsetting each object in \code{...}.
All genes are used by default.}
\item{auto.order}{Logical scalar indicating whether re-ordering of batches should be performed to maximize the number of MNN pairs at each step.}
\item{pc.input}{Logical scalar indicating whether the values in \code{...} are already low-dimensional, e.g., the output of \code{\link{multiBatchPCA}}.}
\item{assay.type}{A string or integer scalar specifying the assay containing the expression values, if SingleCellExperiment objects are present in \code{...}.}
\item{use.spikes}{A logical scalar specifying whether spike-in transcripts should be used, if SingleCellExperiment objects are present in \code{...}.}
\item{BPPARAM}{A BiocParallelParam object specifying whether the PCA and nearest-neighbor searches should be parallelized.}
}

\value{
A named list containing:
\describe{
\item{\code{corrected}:}{A matrix with number of columns equal to \code{d}, and number of rows equal to the total number of cells in \code{...}.
Cells are ordered in the same manner as supplied in \code{...} if \code{auto.order=FALSE},
otherwise the batches will be re-ordered as determined by the algorithm.}
\item{\code{origin}:}{A DataFrame containing the \code{batch} field (integer, or character if \code{...} is named), 
which specifies the batch of origin for each row (i.e., cell) in \code{corrected};
and the \code{cell} field (integer), which specifies the column of origin for each row in \code{corrected}.} 
\item{\code{pairs}:}{A list of DataFrames specifying which pairs of cells in \code{corrected} were identified as MNNs at each step.} 
}}

\details{
This function provides a variant of the \code{\link{mnnCorrect}} function, modified for speed and more robust performance.
In particular:
\itemize{
\item It performs a multi-sample PCA via \code{\link{multiBatchPCA}} and subsequently performs all calculations in the PC space.
This reduces computational work and provides some denoising - see, comments in \code{?\link{denoisePCA}}.
As a result, though, the corrected output cannot be interpreted on a gene level and is useful only for cell-level comparisons, e.g., clustering and visualization.
\item The correction vector for each cell is directly computed from its \code{k} nearest neighbours in the same batch.
Specifically, only the \code{k} nearest neighbouring cells that \emph{also} participate in MNN pairs are used.
Each MNN-participating neighbour is weighted by distance from the current cell, using a tricube scheme with bandwidth equal to the median distance multiplied by \code{ndist}.
This ensures that the correction vector only uses information from the closest cells, improving the fidelity of local correction.
\item Issues with \dQuote{kissing} are avoided with a two-step procedure that removes variation along the batch effect vector.
First, the average correction vector across all MNN pairs is computed.
Cell coordinates are adjusted such that all cells in a single batch have the same position along this vector.
The correction vectors are then recalculated with the adjusted coordinates (but the same MNN pairs).
}

The default setting of \code{cos.norm=TRUE} provides some protection against differences in scaling for arbitrary log-expression matrices.
However, if possible, we recommend using the output of \code{\link{multiBatchNorm}} as input to \code{fastMNN}.
This will equalize coverage on the count level before the log-transformation, which is a more accurate rescaling than cosine normalization on the log-values.
}

\section{Controlling the merge order}{
By default, batches are merged in the user-supplied order.
However, if \code{auto.order=TRUE}, batches are ordered to maximize the number of MNN pairs at each step.
The aim is to improve the stability of the correction by first merging more similar batches with more MNN pairs.
This can be somewhat time-consuming as MNN pairs need to be iteratively recomputed for all possible batch pairings,
and it is often more convenient for the user to specify an appropriate ordering based on prior knowledge about the batches.

Further control of the merge order can be achieved by performing the multi-sample PCA outside of this function with \code{\link{multiBatchPCA}}.
Then, batches can be progressively merged by repeated calls to \code{fastMNN} with \code{pc.input=TRUE}.
This is useful in situations where the order of batches to merge is not straightforward, e.g., involving hierarchies of batch similarities. 
We only recommend this mode for advanced users, and note that:
\itemize{
    \item \code{\link{multiBatchPCA}} will not perform cosine-normalization, 
so it is the responsibility of the user to cosine-normalize each batch beforehand to recapitulate results with \code{cos.norm=TRUE}.
    \item \code{\link{multiBatchPCA}} must be run on all samples at once, to ensure that all cells are projected to the same low-dimensional space.
    \item Setting \code{pc.input=TRUE} is criticial to avoid unnecessary (and incorrect) cosine-normalization and PCA within each step of the merge.
}
See the Examples below for how PC input should be used.
}

\author{
Aaron Lun    
}

\seealso{
\code{\link{mnnCorrect}},
\code{\link[irlba]{irlba}},
\code{\link{multiBatchNorm}}
}

\examples{
B1 <- matrix(rnorm(10000), ncol=50) # Batch 1 
B2 <- matrix(rnorm(10000), ncol=50) # Batch 2
out <- fastMNN(B1, B2) # corrected values

# An equivalent approach with PC input.
cB1 <- cosineNorm(B1)
cB2 <- cosineNorm(B2)
pcs <- multiBatchPCA(cB1, cB2)
out.2 <- fastMNN(pcs[[1]], pcs[[2]], pc.input=TRUE)
all.equal(out, out.2) # should be TRUE
}
