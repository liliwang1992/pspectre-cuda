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

#include "pow.hpp"
#include "verlet.hpp"
#include <cufftw.h>

using namespace std;

/**
 * This is where the equations of motion for the fields are actually evaluated.
 * The first and second time derivatives of the fields are computed in accordance
 * with the Klein-Gordon equation, which is written in program units and
 * transformed to momentum-space. Note that the choice of program units has eliminated
 * the first-time-derivative term from the second-time-derivative equation.
 */

#define pow2(x) ((x)*(x))
#define pow4(x) ((x)*(x)*(x)*(x))
__device__ double dphidotdt(double phi, double chi,
			    double chi2phi, double phi3,
			    double phi5, double phi_md,
			    double a_t, double adot_t,
			    double addot_t, double mom2,
			    model_params<double> mp)
{
	return -pow(a_t, -2. * mp.rescale_s - 2.) * mom2 * phi +
		mp.rescale_r * ((mp.rescale_s - mp.rescale_r + 2) * pow2(adot_t/a_t) + addot_t/a_t)*phi -
		pow(a_t, -2.*mp.rescale_s - 2. * mp.rescale_r)/pow2(mp.rescale_B)*(
			(
				(mp.md_e_phi != 0) ? pow(a_t, 2. * mp.rescale_r) * phi_md :
				pow2(mp.m_phi) * pow(a_t, 2. * mp.rescale_r) * phi
				) +
			mp.lambda_phi/pow2(mp.rescale_A) * phi3 +
			pow2(mp.g/mp.rescale_A)*chi2phi +
			mp.gamma_phi/pow4(mp.rescale_A) * pow(a_t, -2. * mp.rescale_r) * phi5
			);
}

__device__ double dchidotdt(double phi, double chi,
			    double phi2chi, double chi3,
			    double chi5, double chi_md,
			    double a_t, double adot_t,
			    double addot_t, double mom2,
			    model_params<double> mp)
{
	return -pow(a_t, -2. * mp.rescale_s - 2.) * mom2 * chi +
		mp.rescale_r * ((mp.rescale_s - mp.rescale_r + 2) * pow2(adot_t/a_t) + addot_t/a_t)*chi -
		pow(a_t, -2.*mp.rescale_s - 2. * mp.rescale_r)/pow2(mp.rescale_B)*(
			(
				(mp.md_e_chi != 0) ? pow(a_t, 2. * mp.rescale_r) * chi_md :
				pow2(mp.m_chi) * pow(a_t, 2. * mp.rescale_r) * chi
				) +
			mp.lambda_chi/pow2(mp.rescale_A) * chi3 +
			pow2(mp.g/mp.rescale_A)*phi2chi +
			mp.gamma_chi/pow4(mp.rescale_A) * pow(a_t, -2. * mp.rescale_r) * chi5
			);
}

__global__ void verlet_init_kernel(model_params<double> mp,
				   fftw_complex *phi_p, fftw_complex *chi_p,
				   fftw_complex *chi2phi_p, fftw_complex *phi2chi_p,
				   fftw_complex *phi3_p, fftw_complex *chi3_p,
				   fftw_complex *phi5_p, fftw_complex *chi5_p,
				   fftw_complex *phi_md_p, fftw_complex *chi_md_p,
				   fftw_complex *phiddot, fftw_complex *chiddot,
				   double a, double adot, double addot,
				   int n)
{
	int x = blockIdx.x;
	int y = blockIdx.y;
	int z = threadIdx.x;
	int px = x <= n/2 ? x : x - n;
	int py = y <= n/2 ? y : y - n;
	int pz = z;
	int idx = z + (n/2+1)*(y + n*x);
	double mom2 = pow2(mp.dp)*(pow2(px) + pow2(py) + pow2(pz));

	#pragma unroll
	for (int c = 0; c < 2; ++c) {
		double phi = phi_p[idx][c], chi = chi_p[idx][c],
			chi2phi = chi2phi_p[idx][c], phi2chi = phi2chi_p[idx][c],
			phi3 = mp.lambda_phi != 0 ? phi3_p[idx][c] : 0.0,
			chi3 = mp.lambda_chi != 0 ? chi3_p[idx][c] : 0.0,
			phi5 = mp.gamma_phi != 0 ? phi5_p[idx][c] : 0.0,
			chi5 = mp.gamma_chi != 0 ? chi5_p[idx][c] : 0.0,
			phi_md = mp.md_e_phi != 0 ? phi_md_p[idx][c] : 0.0,
			chi_md = mp.md_e_chi != 0 ? chi_md_p[idx][c] : 0.0;

		phiddot[idx][c] = dphidotdt(phi, chi,
					    chi2phi, phi3,
					    phi5, phi_md,
					    a, adot,
					    addot, mom2,
					    mp);
		chiddot[idx][c] = dchidotdt(phi, chi,
					    phi2chi, chi3,
					    chi5, chi_md,
					    a, adot,
					    addot, mom2,
					    mp);
	}
}

template <typename R>
void verlet<R>::initialize()
{
	R avg_gradient_phi = 0.0, avg_gradient_chi = 0.0;

	integrator<R>::avg_gradients(fs, mp, phi, chi,
		avg_gradient_phi, avg_gradient_chi);

	R avg_V = vi.integrate(phi, chi, ts.a);

	ts.addot = addot = mp.adoubledot(ts.t, ts.a, ts.adot, avg_gradient_phi, avg_gradient_chi, avg_V);
	ddptdt = -mp.rescale_s/mp.rescale_B * pow(ts.a, -mp.rescale_s - 1.) * ts.adot;

	nlt.transform(phi, chi, ts.a);

	phi.switch_state(momentum);
	chi.switch_state(momentum);
	phidot.switch_state(momentum);
	chidot.switch_state(momentum);

	phiddot.switch_state(momentum);
	chiddot.switch_state(momentum);

	dim3 nr_blocks(fs.n, fs.n);
	dim3 nr_threads(fs.n/2+1, 1);
	verlet_init_kernel<<<nr_blocks, nr_threads>>>(
		mp,
		phi.mdata.ptr, chi.mdata.ptr,
		nlt.chi2phi.mdata.ptr, nlt.phi2chi.mdata.ptr,
		nlt.phi3.mdata.ptr, nlt.chi3.mdata.ptr,
		nlt.phi5.mdata.ptr, nlt.chi5.mdata.ptr,
		nlt.phi_md.mdata.ptr, nlt.chi_md.mdata.ptr,
		phiddot.mdata.ptr, chiddot.mdata.ptr,
		ts.a, ts.adot, addot, fs.n);
}

__global__ void verlet_step_kernel(model_params<double> mp,
				   fftw_complex *phi_p, fftw_complex *chi_p,
				   fftw_complex *phidot_p, fftw_complex *chidot_p,
				   fftw_complex *chi2phi_p, fftw_complex *phi2chi_p,
				   fftw_complex *phi3_p, fftw_complex *chi3_p,
				   fftw_complex *phi5_p, fftw_complex *chi5_p,
				   fftw_complex *phi_md_p, fftw_complex *chi_md_p,
				   fftw_complex *phiddot, fftw_complex *chiddot,
				   fftw_complex *phidot_staggered, fftw_complex *chidot_staggered,
				   double a, double adot, double addot, double dt,
				   int n)
{
	int x = blockIdx.x;
	int y = blockIdx.y;
	int z = threadIdx.x;
	int px = x <= n/2 ? x : x - n;
	int py = y <= n/2 ? y : y - n;
	int pz = z;
	int idx = z + (n/2+1)*(y + n*x);

	double mom2 = pow2(mp.dp)*(pow2(px) + pow2(py) + pow2(pz));

	#pragma unroll
	for (int c = 0; c < 2; ++c) {
		double phi = phi_p[idx][c], chi = chi_p[idx][c],
			chi2phi = chi2phi_p[idx][c], phi2chi = phi2chi_p[idx][c],
			phi3 = mp.lambda_phi != 0 ? phi3_p[idx][c] : 0.0,
			chi3 = mp.lambda_chi != 0 ? chi3_p[idx][c] : 0.0,
			phi5 = mp.gamma_phi != 0 ? phi5_p[idx][c] : 0.0,
			chi5 = mp.gamma_chi != 0 ? chi5_p[idx][c] : 0.0,
			phi_md = mp.md_e_phi != 0 ? phi_md_p[idx][c] : 0.0,
			chi_md = mp.md_e_chi != 0 ? chi_md_p[idx][c] : 0.0;

		phiddot[idx][c] = dphidotdt(phi, chi,
					    chi2phi, phi3,
					    phi5, phi_md,
					    a, adot,
					    addot, mom2,
					    mp);
		chiddot[idx][c] = dchidotdt(phi, chi,
					    phi2chi, chi3,
					    chi5, chi_md,
					    a, adot,
					    addot, mom2,
					    mp);

		phidot_p[idx][c] = phidot_staggered[idx][c] + 0.5 * phiddot[idx][c] * dt;
		chidot_p[idx][c] = chidot_staggered[idx][c] + 0.5 * chiddot[idx][c] * dt;
	}
}

template <typename R>
void verlet<R>::step()
{
	adot_staggered = ts.adot + 0.5 * addot * ts.dt;
	dptdt_staggered = dptdt + 0.5 * ddptdt * ts.dt;

	ts.a += ts.adot * ts.dt + 0.5 * addot * pow2(ts.dt);
	ts.physical_time += dptdt * ts.dt + 0.5 * ddptdt * pow2(ts.dt);

	phi.switch_state(momentum);
	chi.switch_state(momentum);
	phidot.switch_state(momentum);
	chidot.switch_state(momentum);
	
	phiddot.switch_state(momentum);
	chiddot.switch_state(momentum);
	phidot_staggered.switch_state(momentum);
	chidot_staggered.switch_state(momentum);

	R total_gradient_phi = 0.0, total_gradient_chi = 0.0;

#ifdef _OPENMP
#pragma omp parallel for reduction(+:total_gradient_phi,total_gradient_chi)
#endif
	
	for (int x = 0; x < fs.n; ++x) {
		int px = (x <= fs.n/2 ? x : x - fs.n);
		for (int y = 0; y < fs.n; ++y) {
			int py = (y <= fs.n/2 ? y : y - fs.n);
			for (int z = 0; z < fs.n/2+1; ++z) {
				int pz = z;
				int idx = z + (fs.n/2+1)*(y + fs.n*x);

				R mom2 = pow2(mp.dp)*(pow2(px) + pow2(py) + pow2(pz));

				for (int c = 0; c < 2; ++c) {

					phidot_staggered.mdata[idx][c] = phidot.mdata[idx][c] + 0.5 * phiddot.mdata[idx][c] * ts.dt;
					chidot_staggered.mdata[idx][c] = chidot.mdata[idx][c] + 0.5 * chiddot.mdata[idx][c] * ts.dt;

					phi.mdata[idx][c] += phidot_staggered.mdata[idx][c]*ts.dt;
					chi.mdata[idx][c] += chidot_staggered.mdata[idx][c]*ts.dt;
				}

				mom2 *= (z == 0 || z == fs.n/2) ? 1 : 2;

				total_gradient_phi += mom2*(pow2(phi.mdata[idx][0]) + pow2(phi.mdata[idx][1]));
				total_gradient_chi += mom2*(pow2(chi.mdata[idx][0]) + pow2(chi.mdata[idx][1]));
			}
		}
	}

	R avg_gradient_phi = total_gradient_phi/pow<2, R>(fs.total_gridpoints);
	R avg_gradient_chi = total_gradient_chi/pow<2, R>(fs.total_gridpoints);

	R avg_V = vi.integrate(phi, chi, ts.a);

	ts.addot = addot = mp.adoubledot_staggered(ts.t, ts.dt, ts.a, adot_staggered, avg_gradient_phi, avg_gradient_chi, avg_V);
	ts.adot = adot_staggered + 0.5 * addot * ts.dt;

	ddptdt = -mp.rescale_s / mp.rescale_B * pow(ts.a, -mp.rescale_s - 1) * ts.adot;
	dptdt = dptdt_staggered + 0.5 * ddptdt * ts.dt;

	nlt.transform(phi, chi, ts.a);

	phi.switch_state(momentum);
	chi.switch_state(momentum);

	dim3 nr_blocks(fs.n, fs.n);
	dim3 nr_threads(fs.n/2+1, 1);
	verlet_step_kernel<<<nr_blocks, nr_threads>>>(
		mp,
		phi.mdata.ptr, chi.mdata.ptr,
		phidot.mdata.ptr, chidot.mdata.ptr,
		nlt.chi2phi.mdata.ptr, nlt.phi2chi.mdata.ptr,
		nlt.phi3.mdata.ptr, nlt.chi3.mdata.ptr,
		nlt.phi5.mdata.ptr, nlt.chi5.mdata.ptr,
		nlt.phi_md.mdata.ptr, nlt.chi_md.mdata.ptr,
		phiddot.mdata.ptr, chiddot.mdata.ptr,
		phidot_staggered.mdata.ptr, chidot_staggered.mdata.ptr,
		ts.a, ts.adot, addot, ts.dt, fs.n);
}

// Explicit instantiations
template class verlet<double>;
