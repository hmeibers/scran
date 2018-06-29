#' @export
#' @importFrom BiocParallel SerialParam
fastMNN <- function(..., k=20, cos.norm=TRUE, d=50, ndist=3, approximate=FALSE, 
    irlba.args=list(), subset.row=NULL, BPPARAM=SerialParam()) 
# A faster version of the MNN batch correction approach.
# 
# written by Aaron Lun
# created 26 May 2018
{

    batches <- list(...) 
    nbatches <- length(batches) 
    if (nbatches < 2L) { 
        stop("at least two batches must be specified") 
    }

    # Checking for identical number of rows (and rownames).
    first <- batches[[1]]
    ref.nrow <- nrow(first)
    ref.rownames <- rownames(first)
    for (b in 2:nbatches) {
        current <- batches[[b]]
        if (!identical(nrow(current), ref.nrow)) {
            stop("number of rows is not the same across batches")
        } else if (!identical(rownames(current), ref.rownames)) {
            stop("row names are not the same across batches")
        }
    }

    # Subsetting to the desired subset of genes, and applying cosine normalization.
    if (!is.null(subset.row)) { 
        subset.row <- .subset_to_index(subset.row, batches[[1]], byrow=TRUE)
        if (!identical(subset.row, seq_len(ref.nrow))) { 
            batches <- lapply(batches, "[", i=subset.row, , drop=FALSE) # Need the extra comma!
        }
    }
    if (cos.norm) { 
        batches <- lapply(batches, FUN=cosine.norm, mode="matrix")
    }
    
    # Performing a multi-sample PCA.
    pc.mat <- .multi_pca(batches, d=d, approximate=approximate, use.crossprod=TRUE, irlba.args=irlba.args)

    refdata <- pc.mat[[1]]
    for (bdx in 2:nbatches) {
        curdata <- pc.mat[[bdx]]
        
        # Finding MNNs between batches and obtaining an estimate of the overall batch vector.
        mnn.sets <- find.mutual.nn(refdata, curdata, k1=k, k2=k, BPPARAM=BPPARAM)
        ave.out <- .average_correction(refdata, mnn.sets$first, curdata, mnn.sets$second)
        overall.batch <- colMeans(ave.out$averaged)

        # Projecting along the batch vector, and shifting all cells to the center _within_ each batch.
        refdata <- .center_along_batch_vector(refdata, overall.batch)
        curdata <- .center_along_batch_vector(curdata, overall.batch)

        # Repeating the MNN discovery, now that the spread along the batch vector is removed.
#        re.mnn.sets <- find.mutual.nn(refdata, curdata, k1=k, k2=k, BPPARAM=BPPARAM)
#        re.ave.out <- .average_correction(refdata, re.mnn.sets$first, curdata, re.mnn.sets$second)

        # Recomputing the correction vectors after removing the within-batch variation.
        re.ave.out <- .average_correction(refdata, mnn.sets$first, curdata, mnn.sets$second)
        
        curdata <- .tricube_weighted_correction(curdata, re.ave.out$averaged, re.ave.out$second, k=k, ndist=ndist)
        refdata <- rbind(refdata, curdata)
    }
    
    # Figuring out what output to return.
    ncells <- vapply(batches, FUN=ncol, FUN.VALUE=0L)
    if (!is.null(names(batches))) {
        batch.ids <- rep(names(batches), ncells)
    } else {
        batch.ids <- rep(seq_along(ncells), ncells)
    }
    return(list(corrected=refdata, batch=batch.ids))
}
 
#' @importFrom DelayedArray DelayedArray t
#' @importFrom DelayedMatrixStats rowMeans2
.multi_pca <- function(mat.list, d=50, approximate=FALSE, irlba.args=list(), use.crossprod=FALSE, BPPARAM=SerialParam()) 
# This function performs a multi-sample PCA, weighting the contribution of each 
# sample to the gene-gene covariance matrix to avoid domination by samples with
# a large number of cells. Expects cosine-normalized and subsetted expression matrices.
{
    if (d > min(nrow(mat.list[[1]]), sum(vapply(mat.list, FUN=ncol, FUN.VALUE=0L)))) {
        stop("'d' is too large for the number of cells and genes")
    }

    all.centers <- 0
    for (idx in seq_along(mat.list)) {
        current <- DelayedArray(mat.list[[idx]])
        centers <- rowMeans2(current)
        all.centers <- all.centers + centers
        mat.list[[idx]] <- current
    }
    all.centers <- all.centers/length(mat.list) # grand average of centers (not using batch-specific centers, which makes compositional assumptions).

    centered <- scaled <- mat.list
    for (idx in seq_along(mat.list)) {
        current <- mat.list[[idx]]
        current <- current - centers # centering each batch by the grand average.
        centered[[idx]] <- current
        current <- current/sqrt(ncol(current)) # downweighting samples with many cells.
        scaled[[idx]] <- t(current)
    }

    # Performing an SVD.
    if (use.crossprod) {
        svd.out <- .fast_svd(scaled, nv=d, irlba.args=irlba.args, approximate=approximate, BPPARAM=BPPARAM)
    } else {
        combined <- as.matrix(do.call(rbind, scaled))
        if (!approximate) { 
            svd.out <- svd(combined, nu=0, nv=d)
        } else {
            svd.out <- do.call(irlba::irlba, c(list(A=combined, nu=0, nv=d), irlba.args))
        }
    }

    # Projecting the scaled matrices back into this space.
    final <- centered
    for (idx in seq_along(centered)) {
        final[[idx]] <- as.matrix(t(centered[[idx]]) %*% svd.out$v)
    }
    return(final)
}

#' @importFrom DelayedArray t
#' @importFrom BiocParallel bplapply SerialParam
.fast_svd <- function(mat.list, nv, approximate=FALSE, irlba.args=list(), BPPARAM=SerialParam())
# Performs a quick irlba by performing the SVD on XtX or XXt,
# and then obtaining the V vector from one or the other.
{
    nrows <- sum(vapply(mat.list, FUN=nrow, FUN.VALUE=0L))
    ncols <- ncol(mat.list[[1]])
    
    # Creating the cross-product without actually rbinding the matrices.
    # This avoids creating a large temporary matrix.
    flipped <- nrows > ncols
    if (flipped) {
        collected <- bplapply(mat.list, FUN=.delayed_crossprod, BPPARAM=BPPARAM)
        final <- Reduce("+", collected)

    } else {
        final <- matrix(0, nrows, nrows)

        last1 <- 0L
        for (right in seq_along(mat.list)) {
            RHS <- mat.list[[right]]
            collected <- bplapply(mat.list[seq_len(right-1L)], FUN=.delayed_mult, Y=t(RHS), BPPARAM=BPPARAM)
            rdx <- last1 + seq_len(nrow(RHS))

            last2 <- 0L
            for (left in seq_along(collected)) {
                cross.prod <- collected[[left]]
                ldx <- last2 + seq_len(nrow(cross.prod))
                final[ldx,rdx] <- cross.prod
                final[rdx,ldx] <- t(cross.prod)
                last2 <- last2 + nrow(cross.prod)
            }
            
            last1 <- last1 + nrow(RHS)
        }

        tmat.list <- lapply(mat.list, t)
        diags <- bplapply(tmat.list, FUN=.delayed_crossprod, BPPARAM=BPPARAM)
        last1 <- 0L
        for (idx in seq_along(diags)) {
            indices <- last1 + seq_len(nrow(diags[[idx]]))
            final[indices,indices] <- diags[[idx]]
            last1 <- last1 + nrow(diags[[idx]])
        }
    }

    if (approximate) {
        svd.out <- do.call(irlba::irlba, c(list(A=final, nv=nv, nu=0), irlba.args))
    } else {
        svd.out <- svd(final, nv=nv, nu=0)
        svd.out$d <- svd.out$d[seq_len(nv)]
    }
    svd.out$d <- sqrt(svd.out$d)

    if (flipped) {
        # XtX means that the V in the irlba output is the original Vm,
        # which can be directly returned.
        return(svd.out)
    }

    # Otherwise, XXt means that the V in the irlba output is the original U.
    # We need to multiply the left-multiply the matrices by Ut, and then by D^-1.
    Ut <- t(svd.out$v)
    last <- 0L
    Vt <- matrix(0, nv, ncols)
    for (mdx in seq_along(mat.list)) {
        curmat <- mat.list[[mdx]]
        idx <- last + seq_len(nrow(curmat))
        Vt <- Vt + as.matrix(Ut[,idx,drop=FALSE] %*% curmat)
        last <- last + nrow(curmat)
    }
    Vt <- Vt / svd.out$d

    return(list(d=svd.out$d, v=t(Vt)))
}

.delayed_crossprod <- function(X, BPPARAM=SerialParam()) 
# DelayedMatrix crossprod, 1000 rows at a time.
{
    CHUNK <- 1000L
    last <- 0L
    output <- 0
    finish <- nrow(X)

    repeat {
        previous <- last + 1L
        last <- min(last + CHUNK, finish)
        block <- as.matrix(X[previous:last,,drop=FALSE])
        output <- output + crossprod(block)
        if (last==finish) { break }
    }

    return(output)
}

.delayed_mult <- function(X, Y, BPPARAM=SerialParam()) 
# DelayedMatrix multiplication, 1000 columns at a time.
{
    CHUNK <- 1000L
    last <- 0L
    output <- matrix(0, nrow(X), ncol(Y))
    finish <- ncol(Y)
    stopifnot(identical(ncol(X), nrow(Y)))

    repeat {
        previous <- min(last + 1L, finish)
        last <- min(last + CHUNK, finish)
        indices <- previous:last
        output[,indices] <- as.matrix(X %*% as.matrix(Y[,indices,drop=FALSE]))
        if (last==finish) { break }
    }

    return(output)
}

.average_correction <- function(refdata, mnn1, curdata, mnn2)
# Computes correction vectors for each MNN pair, and then
# averages them for each MNN-involved cell in the second batch.
{
    corvec <- refdata[mnn1,,drop=FALSE] - curdata[mnn2,,drop=FALSE]
    corvec <- rowsum(corvec, mnn2)
    npairs <- table(mnn2)
    stopifnot(identical(names(npairs), rownames(corvec)))
    corvec <- corvec/as.vector(npairs)
    list(averaged=corvec, second=as.integer(names(npairs)))
}

.center_along_batch_vector <- function(mat, batch.vec) 
# This removes any variation along the overall batch vector within each matrix.
{
    batch.vec <- batch.vec/sqrt(sum(batch.vec^2))
    batch.loc <- as.vector(mat %*% batch.vec)
    central.loc <- mean(batch.loc)
    mat <- mat + outer(central.loc - batch.loc, batch.vec, FUN="*")
    return(mat)
}

#' @importFrom kmknn queryKNN
.tricube_weighted_correction <- function(curdata, correction, in.mnn, k=20, ndist=3)
# Computing tricube-weighted correction vectors for individual cells,
# using the nearest neighbouring cells _involved in MNN pairs_.
{
    cur.uniq <- curdata[in.mnn,,drop=FALSE]
    safe.k <- min(k, nrow(cur.uniq))
    closest <- queryKNN(query=curdata, X=cur.uniq, k=safe.k)

    middle <- ceiling(safe.k/2L)
    mid.dist <- closest$distance[,middle]
    rel.dist <- closest$distance / (mid.dist * ndist)
    rel.dist[rel.dist > 1] <- 1

    tricube <- (1 - rel.dist^3)^3
    weight <- tricube/rowSums(tricube)
    for (kdx in seq_len(safe.k)) {
        curdata <- curdata + correction[closest$index[,kdx],,drop=FALSE] * weight[,kdx]
    }
    
    return(curdata)
}