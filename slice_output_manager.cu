/*
 * SpectRE - A Spectral Code for Reheating
 * Copyright (C) 2009-2010 Hal Finkel, Nathaniel Roth and Richard Easther
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE AUTHORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "slice_output_manager.hpp"
#include "reduction_helper.hpp"
#include "pow.hpp"

#include <cstdio>
#include <cstring>
#include <cmath>
#include <unistd.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>

__device__ __host__ double compute_energy_scaling(double a, double adot)
{
	return 8. * M_PI /(3. * pow2(RESCALE_A) * pow(a, 2.*RESCALE_R) * pow2(adot/a));
}

__device__ double compute_phi(double a, double phi)
{
	return pow(a, -RESCALE_R) * phi/RESCALE_A;
}

__device__ double compute_V_phys(double a, double phi IF_CHI_ARG(, double chi))
{
	return model_params::V(phi IF_CHI_ARG(, chi), a);
}

__device__ double compute_T_phi_phys(double a, double adot, double phi, double phidot)
{
	return 0.5 * pow2(phidot) - RESCALE_R * adot/a * phi*phidot +
		pow2(RESCALE_R * adot/a ) * 0.5 * pow2(phi);
}

#if ENABLE_CHI != 0
__device__ double compute_T_chi_phys(double a, double adot,
				     double chi,double chidot)
{
	return 0.5 * pow2(chidot) - RESCALE_R * adot/a * chi*chidot +
		pow2(RESCALE_R * adot/a) * 0.5 * pow2(chi);
}
#endif

__device__ double compute_G_phi_phys(double a, double phigradx, double phigrady, double phigradz)
{
	return pow(a, -2.*RESCALE_S - 2.) * 0.5 * (pow2(phigradx) + pow2(phigrady) + pow2(phigradz));
}

#if ENABLE_CHI != 0
__device__ double compute_G_chi_phys(double a, double chigradx, double chigrady, double chigradz)
{
	return pow(a, -2.*RESCALE_S - 2.) * 0.5 * (pow2(chigradx) + pow2(chigrady) + pow2(chigradz));
}
#endif

__device__ double compute_rho_phys(double a, double adot,
				   double phi, IF_CHI_ARG(double chi,)
				   double phidot, IF_CHI_ARG(double chidot,)
				   double phigradx, IF_CHI_ARG(double chigradx,)
				   double phigrady, IF_CHI_ARG(double chigrady,)
				   double phigradz IF_CHI_ARG(,double chigradz))
{
	return compute_V_phys(a, phi IF_CHI_ARG(, chi))
		+ compute_T_phi_phys(a, adot, phi, phidot)
		IF_CHI(+ compute_T_chi_phys(a, adot, chi, chidot))
		+ compute_G_phi_phys(a, phigradx, phigrady, phigradz)
		IF_CHI(+ compute_G_chi_phys(a, chigradx, chigrady, chigradz));
}

__device__ double compute_rho(double a, double adot,
			      double phi, IF_CHI_ARG(double chi,)
			      double phidot, IF_CHI_ARG(double chidot,)
			      double phigradx, IF_CHI_ARG(double chigradx,)
			      double phigrady, IF_CHI_ARG(double chigrady,)
			      double phigradz IF_CHI_ARG(,double chigradz))
{
	return compute_energy_scaling(a, adot) *
		compute_rho_phys(a, adot, phi, IF_CHI_ARG(chi,) phidot, IF_CHI_ARG(chidot,)
				 phigradx, IF_CHI_ARG(chigradx,) phigrady,
				 IF_CHI_ARG(chigrady,) phigradz IF_CHI_ARG(, chigradz));
}

__global__ void compute_phi_kernel(double *phi, double *out,
				   double a)
{
	int x = blockIdx.x;
	int y = blockIdx.y;
	int z = threadIdx.x;
	int ldl = 2*(NGRIDSIZE/2+1);
	int idx = z + ldl*(y + NGRIDSIZE*x);
	int out_idx = z + NGRIDSIZE*(y + NGRIDSIZE*x);
	out[out_idx] = compute_phi(a, phi[idx]);
}

__global__ void compute_rho_kernel(double *phi, IF_CHI_ARG(double *chi,)
				   double *phidot, IF_CHI_ARG(double *chidot,)
				   double *phigradx, IF_CHI_ARG(double *chigradx,)
				   double *phigrady, IF_CHI_ARG(double *chigrady,)
				   double *phigradz, IF_CHI_ARG(double *chigradz,)
				   double *out, double a, double adot)
{
	int x = blockIdx.x;
	int y = blockIdx.y;
	int z = threadIdx.x;
	int ldl = 2*(NGRIDSIZE/2+1);
	int idx = z + ldl*(y + NGRIDSIZE*x);
	int out_idx = z + NGRIDSIZE*(y + NGRIDSIZE*x);
	out[out_idx] = compute_rho(a, adot,
				   phi[idx], IF_CHI_ARG(chi[idx],)
				   phidot[idx], IF_CHI_ARG(chidot[idx],)
				   phigradx[idx], IF_CHI_ARG(chigradx[idx],)
				   phigrady[idx], IF_CHI_ARG(chigrady[idx],)
				   phigradz[idx] IF_CHI_ARG(,chigradz[idx]));
}

static void write_array_to_file(double_array_gpu &arr, const char *field, int idx)
{
	char name[32] = {0};
	snprintf(name, sizeof(name), "%s_%.5d.bin", field, idx);
	int fd = open(name, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
	if (fd == -1) {
		perror("write_array_to_file: open failed.");
	} else {
		double *p = (double *) malloc(arr.alloc_size());
		if (p == NULL) {
			std::cout << "write_array_to_file: malloc fail" << std::endl;
		}
		arr.download(p);
		pwrite(fd, p, arr.alloc_size(), 0);
		free(p);
	}
	close(fd);
}

template <typename R>
void slice_output_manager<R>::output()
{
	if (ts.physical_time * RESCALE_B < BEGIN_OUTPUT_TIME) {
		return;
	}

	gc.compute();

	phi.switch_state(position);
	phidot.switch_state(position);

	IF_CHI(chi.switch_state(position);
	       chidot.switch_state(position);)

	auto phi_out = double_array_gpu(NGRIDSIZE, NGRIDSIZE, NGRIDSIZE);
	auto rho_out = double_array_gpu(NGRIDSIZE, NGRIDSIZE, NGRIDSIZE);

	dim3 nr_blocks(NGRIDSIZE, NGRIDSIZE);
	dim3 nr_threads(NGRIDSIZE, 1);
	compute_phi_kernel<<<nr_blocks, nr_threads>>>(phi.data.ptr, phi_out.ptr(), ts.a);
	compute_rho_kernel<<<nr_blocks, nr_threads>>>(phi.data.ptr, IF_CHI_ARG(chi.data.ptr,)
						      phidot.data.ptr, IF_CHI_ARG(chidot.data.ptr,)
						      gc.phigradx.data.ptr, IF_CHI_ARG(gc.chigradx.data.ptr,)
						      gc.phigrady.data.ptr, IF_CHI_ARG(gc.chigrady.data.ptr,)
						      gc.phigradz.data.ptr, IF_CHI_ARG(gc.chigradz.data.ptr,)
						      rho_out.ptr(), ts.a, ts.adot);
	write_array_to_file(phi_out, "phi", bin_idx);
	write_array_to_file(rho_out, "rho", bin_idx);

	++bin_idx;
}

// Explicit instantiations
template class slice_output_manager<double>;
